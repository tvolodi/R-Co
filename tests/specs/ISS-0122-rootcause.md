# Test Spec — ISS-0122 Root Cause (GitHub #388, followup)

**Parent spec:** [`tests/specs/ISS-0122.md`](ISS-0122.md) — the four-TC integration spec authored during the first WF-03 pass.

**Run:** `WF03-gh388-rootcause-20260802` (followup to `WF03-gh388-20260802`).

**Priority:** MUST. ISS-0122 is a BLOCKER for `test-runner` Step 4. This followup spec records the second-pass root causes that the first spec missed and the test/migration contracts that the fix must satisfy.

**Branch:** `feature/WF03-gh388-rootcause-20260802`. Implementation MUST be on this branch.

---

## Summary

The first WF-03 pass on ISS-0122 (commits on `feature/WF03-gh388-20260802`) closed TC-01 and TC-02 with migrations 1107–1109, but two regressions surfaced when the integration suite was re-run end-to-end:

- **TC-ISS-0122-03 was reported "FIXED" prematurely.** The validator body in every `tenant_*` schema was still passing a hard-coded `NULL` for `trace_id` to `bpm_audit_compute_chain_hash(...)`, while the trigger (`tenant_default.bpm_audit_apply_chain_hash`, set up by 1107/1109) hashes against `NEW.trace_id`. The canonical payload embeds `trace_id=<value>` vs `trace_id=~` literally, so the validator's expected hash diverged from the trigger's stored hash and TC-03 reported `(1 PrevHashMismatch, 2 ChainHashMismatch)` per per-test tenant.

- **TC-ISS-0122-04 hit SQLSTATE `42P08 ambiguous parameter`.** The dynamically-built INSERT in `tests/integration/audit_chain_utf8_test.zig` (worker context, lines ~388 onwards) embedded `$1` twice in the same `INSERT` — once as the `tenant_id` placeholder, once as `$1::text` inside a `resource_id` concat expression. PostgreSQL raises `42P08` when a single parameter slot is referenced more than once in the same statement.

This followup delivers migration **1111** (per-tenant validator `CREATE OR REPLACE` that re-applies the 1110 body but passes `r.trace_id` instead of `NULL`) and a test-source fix (drop `$1::text` from the resource_id expression so `$1` is referenced exactly once per statement). Both fixes preserve the original signatures; nothing else in the audit pipeline changes.

The integration test file `tests/integration/audit_chain_utf8_test.zig` is the source of truth for TC-01..04 — this spec describes the contracts that file must satisfy after the root-cause fix lands, so a future regression cannot silently re-introduce the same divergences.

---

## TCs covered

All four TCs live in `tests/integration/audit_chain_utf8_test.zig` and are guarded by `TestHarness.init()` — missing `BPM_TEST_DB_URL` returns `error.MissingTestDatabaseUrl` (no silent skip on MUST per DIRECTIVE T-1).

| Test | Pre-fix status | Post-fix status | Root cause (this followup) |
|---|---|---|---|
| **TC-ISS-0122-01** ASCII TEXT resource_id writes through the chain trigger | PASS | PASS (unchanged) | n/a — happy path of the 1107 migration. Trigger and validator agree on the SHA-256 input when both pass `r.trace_id` / `NEW.trace_id`. |
| **TC-ISS-0122-02** Non-UTF-8 resource_id writes WITHOUT C22021 propagation | PASS | PASS (unchanged) | n/a — 1107's `EXCEPTION WHEN OTHERS THEN RETURN NEW` + `<invalid-utf8:N>` normaliser in the trigger already covers this. Validator's per-row `BEGIN ... EXCEPTION WHEN OTHERS` (1110/1111) keeps the validator from raising either. |
| **TC-ISS-0122-03** Validator returns empty `issues[]` after the non-UTF-8 insert | **FAIL** before migration 1111 (`1 PrevHashMismatch + 2 ChainHashMismatch`) | **PASS** after migration 1111 | Per-tenant validator body (1110) passed `NULL` to `bpm_audit_compute_chain_hash`; trigger (1109) hashes against `NEW.trace_id`. SHA-256 of payload with `trace_id=<value>` ≠ SHA-256 of payload with `trace_id=~`, so the validator's expected hash mismatched the stored hash for every chained row. Fix: 1111 re-applies the per-tenant body with `r.trace_id` (matches the public-schema body 1108 already used). |
| **TC-ISS-0122-04** Concurrent non-UTF-8 inserts do not fork the chain | **FAIL** before test-source fix (SQLSTATE `42P08 ambiguous parameter` at the worker INSERT) | **PASS** after parameter split | The worker's per-iteration INSERT statement reused `$1` (the `tenant_id` UUID placeholder) inside a `resource_id` concat expression as `$1::text`. PG rejects this with `42P08`. Fix: drop `$1::text` from the resource_id expression so `$1` is referenced exactly once per INSERT statement. |

### TC-by-TC root cause in detail

**TC-03 root cause (validator / trigger trace_id asymmetry).** Migration 1108 created `public.bpm_audit_validate_chain` with the trace_id argument correctly forwarded (`r.trace_id`). Migration 1110 re-applied the same body to every `tenant_*` schema but, to keep the per-tenant function compiling against the audit_entries shape at the time, hard-coded the inner `bpm_audit_compute_chain_hash` call's `trace_id` argument to `NULL`:

```sql
expected_chain := %I.bpm_audit_compute_chain_hash(
    r.tenant_id, r.audit_id, r.actor_id, r.action,
    r.resource_type, v_safe_resource_id, r."timestamp",
    r.before_state, r.after_state, r.pipeline_run_id,
    r.payload_full, r.prev_chain_hash,
    NULL                                          -- was: NULL
);
```

The trigger `tenant_default.bpm_audit_apply_chain_hash` hashes against `NEW.trace_id` (i.e. the literal `'iss0122-test'` value written by TC-03's INSERT), so the canonical payload's `trace_id=<value>` substring flipped the SHA-256. The per-tenant validator's expected hash diverged from every chained row's stored hash and `bpm_audit_validate_chain(...)` returned one `PrevHashMismatch` (chain head) plus two `ChainHashMismatch` entries (the chained rows).

The fix (migration **1111**) is a `CREATE OR REPLACE` of `tenant_<n>.bpm_audit_validate_chain(...)` whose body is byte-identical to 1110 except the inner call passes `r.trace_id` instead of `NULL`. `CREATE OR REPLACE` preserves the function OID, so no callers, views, triggers, or tests need to be rebound. The per-tenant loop wraps each `CREATE OR REPLACE` in `BEGIN ... EXCEPTION WHEN OTHERS` so one malformed tenant schema cannot abort the loop.

**TC-04 root cause (test source: $1 reused in the same statement).** The test uses `pg.Conn` directly (not the harness's transactional wrapper) so the per-tenant advisory lock acquired by the trigger is released between INSERTs — required for genuine concurrency. The worker builds its INSERT dynamically with `std.fmt.bufPrint` and embeds the tenant/actor placeholders as `$1, $2` while the resource_id concat expression referenced `$1::text`:

```sql
INSERT INTO audit_entries (
    audit_id, tenant_id, actor_id, ...
) VALUES (
    gen_random_uuid(), $1, $2,           -- $1 = tenant_id (UUID)
    '...',
    convert_from(decode('e2aaaa','hex'),'UTF8') || '-a-' || '$1::text',  -- ← same slot twice
    ...
);
```

PostgreSQL raises `SQLSTATE 42P08 (ambiguous parameter)` because a single `$N` slot can only be referenced once per statement. The fix is to drop `$1::text` from the resource_id expression — the resource_id is built from the decoded byte sequence plus the per-thread suffix and per-iteration index (both already embedded as literals via the `bufPrint` template), so removing `$1::text` does not change semantics.

---

## Migration contract — 1111

**File:** `migrations/1111_iss0122_validator_pass_trace_id.sql` (existing).

**Required invariants:**

1. **Re-applies the validator body only.** The migration MUST NOT touch `bpm_audit_apply_chain_hash` (trigger), `bpm_audit_compute_chain_hash` (chain-hash function), `bpm_audit_chain_canonical_payload` (canonical-payload builder), or any other audit function. Those are already correct (1107/1109). Re-running them risks behavioural drift.

2. **Signatures preserved.** `CREATE OR REPLACE FUNCTION %I.bpm_audit_validate_chain(p_tenant_id UUID, p_from_timestamp TIMESTAMPTZ, p_to_timestamp TIMESTAMPTZ, p_stop_on_first_error BOOLEAN)` and the `RETURNS TABLE (...)` column list MUST match migration 1108/1110 byte-for-byte. Any caller depending on the existing column list stays compilable.

3. **Behaviour change is exactly one argument.** Inside the validator body, the inner call to `%I.bpm_audit_compute_chain_hash(...)` MUST pass `r.trace_id` for the trace_id argument (the 13th positional argument). All other 12 arguments MUST be unchanged from migration 1110.

4. **Body byte-equivalence to 1110 except for trace_id.** The `v_zero_sentinel`, `v_hash_zero_sentinel`, `v_chain_hash_null`, chain-start guard, duplicate detection, `prev_hash` continuity check, `LegacyGapAfterChainStart`/`InvalidHashFormat` short-circuits, and `p_stop_on_first_error` return paths MUST be preserved. The only textual diff against 1110 is the `NULL` → `r.trace_id` substitution at the inner compute call site.

5. **Per-tenant loop is fault-tolerant.** Each `CREATE OR REPLACE` MUST be wrapped in `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE NOTICE ...` so a single malformed tenant schema cannot abort the loop and block subsequent tenants.

6. **`CREATE OR REPLACE`, not `CREATE`.** Using `CREATE` would force a `DROP FUNCTION` first, which drops the function OID and breaks every dependent view/trigger. `CREATE OR REPLACE` keeps the OID stable.

7. **No backfill of historical rows.** Historical rows written under 1107/1109/1110 have already-correct `chain_hash` values (the trigger is the writer). The validator only re-derives expected hashes from current rows; there is no migration-time data fix needed.

8. **Schema scope.** The migration MUST iterate `pg_namespace` rows where `nspname LIKE 'tenant_%'` AND not in `('public', 'information_schema')` AND not `LIKE 'pg_%'`/`'pgtoast%'`/`'pg_temp%'`, ordered by `nspname` ASC for deterministic ordering.

**Filesystem contract:** `migrations/1111_iss0122_validator_pass_trace_id.sql` already exists on the branch (pre-existing artefact). This spec does not modify the migration — it documents the contract the migration must satisfy.

---

## Test parameter contract

The TC-04 INSERT statements in `tests/integration/audit_chain_utf8_test.zig` (the worker `run` closures for `conn_a` and `conn_b`) MUST obey these rules:

1. **Distinct parameter positions per statement.** No `$N` may appear more than once in the same SQL statement. Each `$N` placeholder is bound to exactly one column.

2. **`$1` and `$2` are bound per-iteration via the parameter slice.** The worker's `params` array is `[_][]const u8{ ctx.tenant_id, ctx.actor_id }`, so `$1` is `tenant_id` and `$2` is `actor_id`. Do NOT reference `$1` or `$2` again inside a string-concatenation expression in the same statement — embed the values as literals via `std.fmt.bufPrint` if needed.

3. **`audit_id` is generated server-side.** Use `gen_random_uuid()` (server-side generation) inside the statement rather than passing it via a parameter. This avoids `$3` and keeps the worker parameter slice at exactly two slots.

4. **`resource_id` is fully literal.** The `resource_id` value MUST be built from:
   - `convert_from(decode('e2aaaa','hex'),'UTF8')` (the 0xAA-contaminated byte sequence), AND
   - a per-thread literal suffix (`'-a-'` for conn_a, `'-b-'` for conn_b), AND
   - a per-iteration index literal embedded via `std.fmt.bufPrint`'s `'{d}'` template.
   No parameter placeholder may appear in the resource_id expression.

5. **`trace_id` is a per-thread literal.** `'-a-...'` rows use `trace_id = 'iss0122-test-a'`, `'-b-...'` rows use `trace_id = 'iss0122-test-b'`. These are static strings embedded in the per-thread `bufPrint` template; no parameter placeholder involved.

**Verification snippet** (not part of the test — purely a manual grep that should yield zero matches):

```bash
grep -nE '\\$([0-9]+).*\\$([0-9]+)' tests/integration/audit_chain_utf8_test.zig
```

After the fix this grep returns no matches in the TC-04 worker closures. (Matches in the harness seed INSERT and TC-02 INSERT are fine because those statements use each `$N` exactly once.)

---

## Acceptance criteria

The followup is COMPLETE only when ALL of the following hold:

1. `migrations/1111_iss0122_validator_pass_trace_id.sql` exists on `feature/WF03-gh388-rootcause-20260802` and the inner `bpm_audit_compute_chain_hash(...)` call passes `r.trace_id` (verifiable via `grep -n 'NULL' migrations/1111_iss0122_validator_pass_trace_id.sql` returning zero matches inside the validator body, or by direct line-by-line comparison against the 1110 file).
2. `tests/integration/audit_chain_utf8_test.zig` TC-04 worker closures reference each `$N` exactly once per statement (verifiable via the grep snippet above).
3. `zig build test-integration-audit_chain_utf8` exits 0 — all four TCs PASS.
4. `zig build test-integration` exits 0 — no regression in adjacent suites.
5. `zig build migrate` exits 0 — migration 1111 applies cleanly against a fresh `bpm_test` database.
6. `python3 tools/lint_sql_param_types.py src tests` exits 0 — no BLOCKER/MAJOR type-cast findings.
7. Validator's per-tenant `CREATE OR REPLACE` runs to completion against all `tenant_*` schemas (verifiable via `SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' ORDER BY nspname` returning a non-zero row count and `psql -c "SELECT proname FROM pg_proc WHERE proname = 'bpm_audit_validate_chain'"` returning one row per `tenant_*` schema).
8. TC-03's `SELECT code FROM bpm_audit_validate_chain($1::uuid, NULL, NULL, false)` returns 0 rows for the per-test tenant (verifiable via `zig build test-integration-audit_chain_utf8` and reading TC-03's assertion).
9. No `error.SkipZigTest` is added to TC-01..TC-04 as a workaround (per DIRECTIVE T-1).

---

## Out of scope

- **Refactoring `bpm_audit_apply_chain_hash` (trigger) or `bpm_audit_compute_chain_hash` (chain-hash function).** Those were already correct after 1107/1109. Re-touching them risks behavioural drift; the fix is in the validator only.
- **Re-creating `public.bpm_audit_validate_chain`.** Already correct from 1108. 1111 only re-creates per-tenant bodies.
- **Backfilling historical `chain_hash` values.** The trigger is the writer; historical rows already have correct chain hashes. The validator only re-derives expected hashes from current rows, so no historical data fix is needed.
- **Dropping or renaming `tenant_default.bpm_audit_validate_chain`.** It is identical to the other per-tenant bodies after 1111; renaming it would break view/trigger OID references and trigger a much wider migration.
- **Generalising the per-tenant loop into a reusable helper.** 1111's loop pattern (`DO $$ ... FOR rec IN SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' ... LOOP ... EXCEPTION WHEN OTHERS ... END LOOP`) is intentionally identical to 1110's; generalising it into a helper is a separate ISS and would change the migration's signature without delivering user value.
- **Changing `audit_entries.resource_id` column type.** Migration 1107 already declared it `TEXT`; further changes are out of scope and would invalidate the GBL-082 baseline.
- **Schema drift on `bpm_audit_chain_canonical_payload`.** That function embeds `trace_id=<value>` literally (the source of the asymmetry 1111 fixes); changing the function signature is out of scope — the fix lives at the validator's call site, not at the payload builder.