# ISS-0122 Chain-Hash Fix Design

**Classification:** Type E — fix design for a regression introduced by PR #398 (e5bbaea, "fix(ISS-0122): audit chain UTF-8 resilience"). Two independent failures in `tests/integration/audit_chain_utf8_test.zig` are addressed: a validator/trigger trace-id mismatch in migration 1110 and a placeholder-type ambiguity in the TC-04 INSERT. Both are corrections to prior fix artefacts; no new product behaviour is introduced and no Type A–D Lego parameter file applies.

## Purpose

ISS-0122 followup / GitHub #388 (root cause: WF03-gh388-rootcause-20260802 / ISSUE-FIXER step 01). Two failures remain in `zig build test-integration-iss0122`:

1. **TC-ISS-0122-03** — `bpm_audit_validate_chain($1::uuid, NULL, NULL, false)` returns three issues (1 `PrevHashMismatch`, 2 `ChainHashMismatch`) on the per-tenant validator body that migration 1110 re-creates in every `tenant_*` schema. The validator's expected chain hash is computed with `trace_id = NULL`, while the trigger function `tenant_default.bpm_audit_apply_chain_hash` (migration 1109) computes the stored chain hash with the actual `NEW.trace_id` (e.g. `'iss0122-test'`). The canonical payload embeds the trace-id literal, so the SHA-256 inputs diverge.
2. **TC-ISS-0122-04** — the connection aborts with `C42883 inconsistent types deduced for parameter $1 (text versus uuid)`. The dynamically-built INSERT in TC-04 reuses `$1` in two positions: `tenant_id = $1::uuid` and `resource_id = ... || $1::text || '-i{d}'`. PostgreSQL cannot pick a single type for `$1`, rejects the prepared statement, and every subsequent command in the transaction surfaces `25P02 current transaction is aborted`.

This design fixes both failures with the minimum surface area: a new migration 1111 that re-creates the per-tenant validator body with the correct `trace_id` argument, and a small edit to TC-04 that resolves the `$1` ambiguity by removing the redundant cast.

## Errors

The fix introduces **no new error variants** at any layer:

- The Zig side of `tests/integration/audit_chain_utf8_test.zig` is touched only inside TC-04's `std.fmt.bufPrint` SQL template. The harness error set is unchanged.
- The PostgreSQL side re-creates `tenant_<n>.bpm_audit_validate_chain(...)` via `CREATE OR REPLACE FUNCTION`. The function signature, RETURNS TABLE shape, and emitted error codes (`InvalidHashFormat`, `ChainHashMismatch`, `PrevHashMismatch`, `DuplicateChainHash`, `LegacyGapAfterChainStart`) are byte-for-byte identical to migration 1110's body. The only behavioural change is that the eleventh positional argument to the inner `bpm_audit_compute_chain_hash` call now receives `r.trace_id` instead of `NULL`.
- `tools/lint_sql_param_types.py src tests` continues to report 0 BLOCKER and 0 MAJOR findings after the fix lands; the TC-04 edit strictly reduces ambiguity.

## API contract

### New stored procedure signature (re-creation only)

The function shape is identical to the one shipped by migration 1110. The change is internal to the function body — the eleventh positional argument to the inner `bpm_audit_compute_chain_hash` call is the row's `r.trace_id`, not a hard-coded `NULL`.

```text
FUNCTION bpm_audit_validate_chain(
    p_tenant_id           UUID        DEFAULT NULL,
    p_from_timestamp      TIMESTAMPTZ DEFAULT NULL,
    p_to_timestamp        TIMESTAMPTZ DEFAULT NULL,
    p_stop_on_first_error BOOLEAN     DEFAULT FALSE
)
RETURNS TABLE (
    tenant_id              UUID,
    audit_id               UUID,
    sequence_no            BIGINT,
    code                   TEXT,
    detail                 TEXT,
    expected_prev_chain_hash TEXT,
    observed_prev_chain_hash TEXT,
    expected_chain_hash    TEXT,
    observed_chain_hash    TEXT
)
LANGUAGE plpgsql;
```

`CREATE OR REPLACE FUNCTION` preserves the function OID, so existing references from views, triggers, and tests continue to bind without further changes.

### Inner compute call (the actual change)

The single line that needs to change inside the per-tenant `bpm_audit_validate_chain` body is the call to `tenant_<n>.bpm_audit_compute_chain_hash(...)`:

````text
expected_chain := %I.bpm_audit_compute_chain_hash(
    r.tenant_id,
    r.audit_id,
    r.actor_id,
    r.action,
    r.resource_type,
    v_safe_resource_id,
    r."timestamp",
    r.before_state,
    r.after_state,
    r.pipeline_run_id,
    r.payload_full,
    r.prev_chain_hash,
    r.trace_id          -- was: NULL  (this is the only diff vs migration 1110)
);
````

`bpm_audit_compute_chain_hash` already accepts a `trace_id TEXT` parameter, so no signature change is required on the compute helper. Migration 1110 hard-coded `NULL` to keep the function compiling against the `audit_entries` shape at the time; that workaround is no longer needed because every audit row that has a non-NULL chain hash has a typed `trace_id` column.

### New TC-04 INSERT (replaces the `$1::text` concatenation)

The current TC-04 SQL template embeds the same `$1` placeholder twice with conflicting inferred types. The fix removes the redundant `$1::text` cast; the per-iteration index is already embedded as a literal by `std.fmt.bufPrint`, and the test's continuity assertion does not need the tenant UUID to appear inside `resource_id`.

````zig
const sql = std.fmt.bufPrint(
    &sql_buf,
    \\INSERT INTO audit_entries (
    \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
    \\  "timestamp", before_state, after_state, trace_id
    \\)
    \\VALUES (
    \\  gen_random_uuid(), $1, $2,
    \\  'iss0122.tc04.create',
    \\  'iss0122.parent.tc04',
    \\  convert_from(decode('e2aaaa','hex'),'UTF8') || '-a-' || '-i{d}',
    \\  NOW(), NULL, '{"k":"v"}'::jsonb, 'iss0122-test-a'
    \\)
,
    .{i_a},
) catch |err| return err;
const params = [_][]const u8{ tenant_id, actor_id };
try harness.conn.exec(sql, &params);
````

The same edit applies to the worker thread B SQL template at the same call shape; both threads use a single `$1::uuid` placeholder plus the now-unambiguous per-iteration literal suffix. No new parameter positions are introduced.

## Fix A — chain validator trace_id (migration 1111)

A new migration `migrations/1111_iss0122_validator_pass_trace_id.sql` is shipped alongside the test edit. The migration:

1. Opens a single `BEGIN`/`COMMIT` transaction.
2. Iterates every schema whose name matches `tenant_*` (excluding `public`, `information_schema`, `pg_*`, `pgtoast*`, `pg_temp*`), ordered by schema name for deterministic replay.
3. For each tenant schema, runs `CREATE OR REPLACE FUNCTION <schema>.bpm_audit_validate_chain(...)` with the body from migration 1110 and the single change to the inner `bpm_audit_compute_chain_hash` call: the eleventh positional argument is `r.trace_id` instead of `NULL`. All other logic — the chain-start guard, the zero-sentinel skip, the duplicate detection, the prev-hash continuity check, the error-code mapping, and the `p_stop_on_first_error` short-circuit — is byte-for-byte preserved.
4. Records a `schema_migrations` row with `version = 1111` so `zig build migrate` and the integration harness recognise the migration as applied. The migration is idempotent under `CREATE OR REPLACE` and may be re-run manually if a tenant schema is provisioned after the migration applies.
5. Wraps each per-tenant `CREATE OR REPLACE` in `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ...` so a single malformed tenant schema cannot abort the whole loop. The warning is recorded in the migration log for followup; the loop continues with the next tenant.

The function signature, the `RETURNS TABLE` column list, the `LANGUAGE plpgsql` declaration, and the per-row error semantics are unchanged. The migration does not drop, alter, or recreate any table, index, sequence, constraint, or trigger. The trigger binding `trg_bpm_audit_apply_chain_hash` on `<schema>.audit_entries` remains valid because the function being re-created is `bpm_audit_validate_chain`, not the trigger function. The trigger function `bpm_audit_apply_chain_hash` is left alone — it is already correct in migrations 1107 and 1109.

The migration does not touch the public-schema validator body that migration 1108 ships; that body already passes `r.trace_id` correctly. Re-creating the public body is unnecessary and would only bloat the migration.

## Fix B — test resource_id parameter (audit_chain_utf8_test.zig TC-04)

The TC-04 fix is local to `tests/integration/audit_chain_utf8_test.zig`:

1. In the worker thread B `std.fmt.bufPrint` template, drop the `|| $1::text ||` substring from the `resource_id` expression. The remaining `|| '-i{d}'` literal preserves per-iteration uniqueness inside `resource_id` so the chain-continuity assertion can still detect a fork. The `params` tuple passed to `pg.Conn.exec` is unchanged: `[_][]const u8{ ctx.tenant_id, ctx.actor_id }`.
2. In the connection A loop `std.fmt.bufPrint` template, apply the identical edit: drop the `|| $1::text ||` substring. The `params` tuple stays as `[_][]const u8{ tenant_id, actor_id }`.
3. The chain-continuity walk at the bottom of TC-04 is unchanged. It still asserts that for every consecutive pair of rows in `(timestamp, audit_id)` order, `row[i+1].prev_chain_hash` equals `row[i].chain_hash`, and that the first chained row has `prev_chain_hash IS NULL`. The walk already tolerates rows with `chain_hash IS NULL` (the trigger's EXCEPTION guard path from migration 1107), so the rewritten INSERTs do not change the chain's structural properties.
4. No new imports, no new helpers, no new error variants. The `try` on the `std.fmt.bufPrint` call site is preserved as before.

The fix is the minimum change that resolves the `C42883` type-inference failure. An alternative — moving the index into a separate `$3` parameter — was considered and rejected because it would change the prepared-statement parameter count and require a tuple-shape change in two call sites without any test-coverage benefit.

## Files to change

| File | Change type | Rationale |
|---|---|---|
| `migrations/1111_iss0122_validator_pass_trace_id.sql` | NEW | Re-creates per-tenant `bpm_audit_validate_chain` with the correct `trace_id` argument; transactionally idempotent under `CREATE OR REPLACE`; records `schema_migrations` row. |
| `tests/integration/audit_chain_utf8_test.zig` | EDIT (TC-04 only) | Drop the redundant `|| $1::text ||` substring in both `std.fmt.bufPrint` templates so each placeholder has a single unambiguous type. |

No other file is touched by this design. In particular:

- `src/audit/chain.zig` is not present in this codebase (the audit-chain logic lives entirely in PostgreSQL — migrations 1107, 1108, 1109, 1110, and now 1111). No Zig source file in `src/` changes.
- `tests/integration/helpers.zig` is unchanged. The `TestHarness` API surface and the `newUuid` / `newUuidString` helpers from ISS-0121 are reused as-is.
- `migrations/1109_iss0122_apply_chain_hash_lock_cast.sql` is unchanged. The trigger function `bpm_audit_apply_chain_hash` already computes the chain hash against the actual `NEW.trace_id`; that is the correct behaviour and the source of truth for the validator.
- `migrations/1110_iss0122_validator_zero_sentinel_per_tenant.sql` is unchanged. Migration 1111 supersedes its body but the migration file itself stays in the ledger so the audit chain of schema evolution remains complete.
- `src/design/audit_chain_text_resource_id.md` and the ISS-0122 design artefacts are not modified by this followup. They describe the original UTF-8 fix and remain accurate.

## Acceptance criteria

A reviewer can mark this design PASS when every item below is verifiable in the order listed:

- [ ] `migrations/1111_iss0122_validator_pass_trace_id.sql` exists, opens with `BEGIN;`, closes with `COMMIT;`, and contains a `DO $$ ... $$;` block that iterates every `tenant_*` schema and runs `CREATE OR REPLACE FUNCTION <schema>.bpm_audit_validate_chain(...)` with the body byte-for-byte identical to migration 1110 except for the eleventh positional argument to the inner `bpm_audit_compute_chain_hash` call, which is `r.trace_id` instead of `NULL`.
- [ ] `tests/integration/audit_chain_utf8_test.zig` TC-04 compiles, contains no `$1::text` substring, and still uses exactly two `[]const u8` parameters per `pg.Conn.exec` call: `tenant_id` and `actor_id`.
- [ ] `cmd /c "set BPM_TEST_DB_URL=...&& set BPM_TEST_URL=...&& set BPM_IDP_BASE_URL=...&& zig build test-integration-iss0122"` exits 0 with `+ run test 4 pass, 0 fail (4 total)`. TC-01 and TC-02 stay green; TC-03 and TC-04 turn green from their current red state.
- [ ] `zig build` exits 0.
- [ ] `zig build test` exits 0.
- [ ] `python tools/lint_sql_param_types.py src tests` exits 0 with no BLOCKER and no MAJOR findings.
- [ ] `python tools/lint_design_artefact.py src/design/iss0122_chain_hash_fix.md` exits 0 (the design artefact passes lint).
- [ ] No regression in other audit-chain integration suites — `zig build test-integration-iss202`, `zig build test-integration-iss601`, and the `iss0121` test target still report their previous pass count (no newly failing test).
- [ ] No new variants added to the harness error set, the migration error set, or the test file's `try` chain.

## Out of scope

The following items are explicitly **not** addressed by this design and remain on the backlog for separate workflows:

- **TC-01 / TC-02** are already passing and require no change. Any drift in their behaviour is a regression and belongs in a separate WF-03 followup.
- **Migration 1109 logic** — the trigger function `bpm_audit_apply_chain_hash` is correct and is the source of truth for the chain hash. The validator must converge onto it, not the other way around.
- **Migration 1110 logic** — its validator body is preserved byte-for-byte modulo the trace-id argument. The zero-sentinel skip, the chain-start guard, the duplicate detection, the prev-hash continuity check, and the `p_stop_on_first_error` short-circuit are all retained.
- **Lint rule for dynamically built SQL with ambiguous `$N` placeholders.** TC-04's failure mode is invisible to the current `tools/lint_sql_param_types.py` because the SQL string is split across multiple line-continuation literals inside `std.fmt.bufPrint`. A future WF-03 could extend the linter with a Zig-aware parser, but that is a separate, larger design.
- **Audit chain hash algorithm changes** — the SHA-256 canonical payload format, the per-tenant advisory-lock key derivation, and the per-row `chain_hash` / `prev_chain_hash` columns remain as they were in migration 1107.
- **Cross-tenant validator consolidation** — migration 1111 keeps the per-tenant loop because the existing pattern (one function per schema) is what the rest of the audit chain relies on. A future consolidation to a single schema-qualified helper is a separate refactor.

## Risks & mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | A tenant schema provisioned after migration 1111 applies will not be reached by the per-tenant loop, leaving the validator body at the pre-fix version. | Low | High — the regression re-appears in the new tenant. | Migration 1111 is idempotent under `CREATE OR REPLACE`; the tenant-provisioning path runs the same migration as a post-provision step. Document the dependency in `migrations/README.md` if a README exists; otherwise add a comment in the tenant-provisioning migration. |
| 2 | Re-running migration 1111 against a schema that already has the corrected body diverges from migration 1109 in some subtle way (e.g. an unrelated later change to `bpm_audit_compute_chain_hash` signature). | Low | Medium — the validator could start raising `42P13` or similar at runtime. | The migration wraps every per-tenant `CREATE OR REPLACE` in `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ...`; the loop logs and continues. `zig build test-integration-iss0122` plus the full integration suite acts as a smoke test. If a divergence is detected, migration 1111 is updated and re-run. |
| 3 | The `r.trace_id` argument to `bpm_audit_compute_chain_hash` in the validator diverges from the trigger's `NEW.trace_id` argument if a future migration adds a column-level transformation (e.g. NULL → sentinel) to one of the two functions. | Low | High — the same regression re-occurs via a different surface. | The design adds a brief note to the validator body (commented) pointing at the trigger function as the source of truth. A followup assertion in `audit_chain_text_resource_id_test.zig` (or a new test) can compare the two compute calls' arguments at runtime to catch drift early. |
| 4 | The TC-04 edit changes the literal `resource_id` written by the test, which could mask a different chain-fork failure mode that the original `$1::text` substring happened to expose. | Very low | Low — the continuity assertion still detects a fork regardless of the literal value. | The chain-continuity walk at the end of TC-04 is structural: it compares consecutive `prev_chain_hash` / `chain_hash` pairs without inspecting `resource_id`. A fork surfaces as a mismatch between consecutive hashes, not as a `resource_id` value mismatch. |
| 5 | The migration's per-tenant loop runs against a `tenant_*` schema that is mid-provisioning (e.g. the schema exists but `audit_entries` has not been created yet) and the `CREATE OR REPLACE` raises because the dependency is missing. | Low | Low — the warning is logged and the loop continues. | The `BEGIN ... EXCEPTION WHEN OTHERS` block already covers this case; the operator sees the warning in the migration log and can re-run migration 1111 after the schema finishes provisioning. The integration suite cannot be impacted because tests provision their own tenants. |
| 6 | The `$1` placeholder reuse in TC-04 was load-bearing for some downstream assertion (e.g. a column that has a `CHECK (resource_id LIKE '%' || tenant_id || '%')` constraint) and removing the `|| $1::text ||` substring causes the test to silently write rows that violate the constraint. | Very low | Low — the audit_entries table has no such CHECK constraint (verified in the migration 1107 ledger). | A pre-flight `psql` query against `information_schema.check_constraints` confirms no CHECK constraint on `resource_id`. If a future migration adds one, the test edit must be revisited, but that is a separate concern. |
