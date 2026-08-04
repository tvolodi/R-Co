# Module: Audit Chain — TEXT `resource_id` + Non-UTF-8 Resilience (ISS-0122)

**Classification:** Type E (Novel / cross-cutting) per `templates/lego-catalog.md`.
**Reason:** the fix touches four migrations, one shared test-helper file, and one new integration test file; it changes the signature of two PL/pgSQL functions and the body of one trigger. It is neither a CRUD endpoint (Type A), nor a list page (Type B), nor a single migration + scaffold (Type C), nor a React Flow node (Type D).

---

## 1. Module purpose (summary)

Migration `GBL-081_iss103_audit_resource_id_text.sql` widened `audit_entries.resource_id` from `UUID` to `TEXT`, and `GBL-082_fix_audit_chain_resource_id_text.sql` already rewrote `bpm_audit_chain_canonical_payload` and `bpm_audit_compute_chain_hash` to take `TEXT`. However, the BEFORE INSERT trigger `bpm_audit_apply_chain_hash` (migration `051_xc02_audit_immutability.sql:30-90`) still calls those functions using `NEW.resource_id` (now `TEXT`) without:

- a defensive UTF-8 validation step on `NEW.resource_id` before the chain-hash computation, and
- a wrapping PL/pgSQL `EXCEPTION` block that downgrades any chain-hash failure (notably `22021 invalid_byte_sequence_for_encoding "UTF8"`) into a logged `WARNING` and a non-blocking `RETURN NEW`, so the audit write can never break a business write.

When a parent-row primary key column (e.g. a TEXT-PK parent table) already contains the byte `0xAA` (most often via shared-DB-state contamination from a previous failed test binary, parallel to ISS-0112 / GH #375), the trigger bubbles `C22021` to the originating `INSERT`, which the PostgreSQL wire protocol reports against the application's first bind parameter (`$1`) and surfaces in `tests/reports` as 85 occurrences of `"invalid byte sequence for encoding UTF8: 0xaa"`. This artefact defines the migration, trigger, function, and test design that make the audit chain hash pipeline accept any well-typed TEXT `resource_id` (including non-UTF-8) without ever blocking the business transaction.

---

## 2. Affected files

| File | Line range | One-line change description |
|---|---|---|
| `migrations/035_adp09_tamper_evident_audit_chain.sql` | 88-130 | No direct change here — already updated by GBL-082; BACKEND-DEV only re-validates the `bpm_audit_chain_canonical_payload` body to confirm it accepts `TEXT` and does not call `lower(p_resource_id::text)` on something that was already `TEXT` (cosmetic). |
| `migrations/051_xc02_audit_immutability.sql` | 30-90 | Replace the body of `bpm_audit_apply_chain_hash()` so the entire predecessor-lookup + chain-hash compute block is wrapped in `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING '...'; RETURN NEW; END;`, and the input `NEW.resource_id` is normalised to a UTF-8-safe placeholder **before** the call to `bpm_audit_compute_chain_hash`. |
| `migrations/GBL-081_iss103_audit_resource_id_text.sql` | 107-180 | No DDL change — confirm the `bpm_audit_resource_info(TEXT,JSONB,JSONB)` `OUT` parameter is still `OUT resource_id TEXT` and the dispatcher in `bpm_audit_on_mutation` propagates it unchanged; if any branch still calls `src->>'id'::uuid` it must be downgraded to `src->>'id'` (text passthrough) so a non-UUID primary key cannot raise `C22P02 invalid_text_representation` before the audit row is even INSERTed. |
| `migrations/GBL-082_fix_audit_chain_resource_id_text.sql` | 94-180 | No DDL change here either — `bpm_audit_chain_canonical_payload` and `bpm_audit_compute_chain_hash` already declare `p_resource_id TEXT`. Confirm `lower(p_resource_id::text)` inside the body is safe (a `TEXT` argument re-cast to `TEXT` is a no-op) and remove the redundant cast only as a `// TODO(codegen)` style cleanup; do **not** change the `p_resource_id TEXT` signature. |
| `migrations/1107_fix_audit_chain_text_resource_id.sql` (NEW) | whole file | New corrective migration placed **after** `1106_iss0125_instance_definition_snapshots_cascade.sql` (the current last migration by numeric prefix). Runs the four DDL outlines in §3 below: drop the existing `bpm_audit_chain_canonical_payload(TEXT)` and `bpm_audit_compute_chain_hash(TEXT)` signatures with `DROP FUNCTION IF EXISTS ... (...)` (dropping both the UUID and the TEXT overloads so PG re-resolves the call site cleanly), then `CREATE OR REPLACE FUNCTION` with the canonical TEXT signatures listed in §4, and finally replace the `bpm_audit_apply_chain_hash()` trigger function so the body is `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING 'audit_chain_skip: %', SQLERRM; RETURN NEW; END;`. The trigger that calls it (`trg_bpm_audit_apply_chain_hash`) is recreated with `DROP TRIGGER IF EXISTS` first to keep the migration idempotent on a long-lived `bpm_test` database. |
| `tests/integration/helpers.zig` | `TestHarness.deinit` (lines around the `self.conn.rollback() catch {};` block) | Add a best-effort `DELETE FROM audit_entries WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND resource_id LIKE '<invalid-utf8:%'` pre-rollback sweep, guarded by `error.ServerError` so it never blocks the harness teardown. Belt-and-suspenders against the same-family state contamination as ISS-0112 — keeps `TC-AUDIT-UTF8`'s normalised placeholder rows from leaking into the next test binary. |
| `tests/integration/audit_chain_utf8_test.zig` (NEW) | whole file | New integration test (`TC-AUDIT-UTF8`) that creates a temporary parent table with a `TEXT` primary key, inserts (a) a pure-ASCII row, (b) a row whose `id` is `convert_from(decode('e2aaaa', 'hex'), 'UTF8')` (an intentionally malformed UTF-8 byte sequence), and asserts (i) no `C22021` propagates back to the parent-row INSERT, (ii) an `audit_entries` row was created for the bad-id INSERT with either the raw (validated) `resource_id` or the normalised placeholder `'<invalid-utf8:N>'`, and (iii) `bpm_audit_validate_chain` still returns an empty `issues[]` for the tenant after both inserts. |

The migration-number choice (`1107`) was made by listing every `migrations/*.sql` file, extracting the leading `\d+` prefix, and selecting one greater than the maximum (`1106_iss0125_instance_definition_snapshots_cascade.sql`); the listing script is at `scratch/_list_last_migration_number.py`.

---

## 3. Schema / migration changes (design-level — no DDL written)

The new migration `migrations/1107_fix_audit_chain_text_resource_id.sql` is **non-destructive** and **idempotent**. It performs exactly four DDL operations, all wrapped in a single `DO $$ ... $$;` block so the whole migration either succeeds or rolls back atomically.

1. **Drop the existing `bpm_audit_chain_canonical_payload` overloads** with `DROP FUNCTION IF EXISTS bpm_audit_chain_canonical_payload(UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT)` and `DROP FUNCTION IF EXISTS bpm_audit_chain_canonical_payload(UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT)`. The UUID overload is the legacy signature from `035_adp09`; the TEXT overload is what `GBL-082` rewrote it to. Dropping both prevents the `42P13 cannot change name of input parameter X` / `42725 function ... is not unique` errors when the new `CREATE OR REPLACE FUNCTION` would otherwise have to pick one of them.

2. **Drop the existing `bpm_audit_compute_chain_hash` overloads** with the same two `DROP FUNCTION IF EXISTS` lines (UUID overload and TEXT overload). Same rationale as #1.

3. **`CREATE OR REPLACE FUNCTION bpm_audit_chain_canonical_payload(...)`** with the new signature in §4. Body keeps the same `concat_ws(E'\n', ...)` shape but writes `'resource_id=' || COALESCE(p_resource_id, '~')` (no `lower()` call, no `::text` cast — `p_resource_id` is already `TEXT`, and `lower()` is undefined for arbitrary `TEXT` if a `0xAA` byte collides with a unicode-lowercase mapping edge case in the cluster's locale).

4. **`CREATE OR REPLACE FUNCTION bpm_audit_compute_chain_hash(...)`** with the new signature in §4. Body keeps the `encode(digest(convert_to(bpm_audit_chain_canonical_payload(...), 'UTF8'), 'sha256'), 'hex')` shape, but the outermost `convert_to(..., 'UTF8')` is now wrapped in a `BEGIN ... EXCEPTION WHEN OTHERS THEN RETURN '0000000000000000000000000000000000000000000000000000000000000000'; END;` plpgsql anonymous-do block so the function never raises — it returns a sentinel "all-zero" SHA-256 hash if the canonical payload cannot be encoded as UTF-8 (this is the canonical OpenSSL `EVP_Digest` failure sentinel; downstream `bpm_audit_validate_chain` will detect it as `chain_hash != NULL AND chain_hash !~ '^[0-9a-f]{64}$'` and log a warning, but the audit row will still be inserted).

5. **Recreate the BEFORE INSERT trigger** with `DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries;` then `CREATE TRIGGER trg_bpm_audit_apply_chain_hash BEFORE INSERT ON audit_entries FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash();`. The trigger function body is updated in step 6.

6. **`CREATE OR REPLACE FUNCTION bpm_audit_apply_chain_hash()`** with the new signature in §4. Body is restructured to:

   - Acquire the per-tenant `pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || NEW.tenant_id::text))` (unchanged from the current trigger — preserves chain-fork protection under concurrency).
   - Read the predecessor `chain_hash` for the tenant (unchanged).
   - **Pre-normalisation step**: if `NEW.resource_id` contains bytes that are not valid UTF-8, replace it in a local variable with `'<' || 'invalid-utf8:' || octet_length(NEW.resource_id) || '>'` and pass **that** to `bpm_audit_compute_chain_hash`. The detection uses `convert_from(convert_to(NEW.resource_id, 'UTF8'), 'UTF8')` inside a `BEGIN ... EXCEPTION WHEN OTHERS THEN ... END;` PL/pgSQL block; on failure, the local variable is set to the placeholder. The **stored** `NEW.resource_id` column value is left untouched — the placeholder is only used in the hash input, so an auditor can still see the original bytes (if a viewer wants to see them via a `bytea` cast). This is the safety valve the design mandates.
   - Call `bpm_audit_compute_chain_hash(...)` with the (possibly normalised) local variable.
   - Wrap the **entire predecessor-lookup + hash call + NEW assignment block** in `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING 'audit_chain_skip: % (audit_id=%s, tenant_id=%s)', SQLERRM, NEW.audit_id, NEW.tenant_id; NEW.chain_hash := NULL; NEW.prev_chain_hash := NULL; END;` so that no `22021`, `22023`, `42703`, `42P10`, or any other error from the chain-hash pipeline ever blocks the INSERT.
   - `RETURN NEW`.

7. **No `ALTER TABLE` / `DROP COLUMN` / `DROP TABLE`** is performed. `audit_entries`, `chain_hash`, `prev_chain_hash`, the unique index `uq_audit_entries_tenant_chain_hash`, and the check constraint `chk_audit_entries_chain_hash_format` are all left exactly as GBL-082 left them. Pre-existing audit rows are preserved.

8. **No data backfill**. The function is forward-compatible: a TEXT `resource_id` that happens to already contain `0xAA` bytes will, after the migration is applied, hash against the placeholder, and the chain validate will still pass because both the writer and the validator use the same normalisation step.

---

## 4. Public interface (function signatures — pseudo-SQL only, no actual DDL)

```text
bpm_audit_chain_canonical_payload(
    p_tenant_id        UUID,
    p_audit_id         UUID,
    p_actor_id         UUID,
    p_action           TEXT,
    p_resource_type    TEXT,
    p_resource_id      TEXT,        -- unchanged from GBL-082
    p_timestamp        TIMESTAMPTZ,
    p_before_state     JSONB,
    p_after_state      JSONB,
    p_pipeline_run_id  UUID,
    p_payload_full     JSONB,
    p_prev_chain_hash  TEXT,
    p_trace_id         TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE sql STABLE;
```

```text
bpm_audit_compute_chain_hash(
    p_tenant_id        UUID,
    p_audit_id         UUID,
    p_actor_id         UUID,
    p_action           TEXT,
    p_resource_type    TEXT,
    p_resource_id      TEXT,        -- unchanged from GBL-082
    p_timestamp        TIMESTAMPTZ,
    p_before_state     JSONB,
    p_after_state      JSONB,
    p_pipeline_run_id  UUID,
    p_payload_full     JSONB,
    p_prev_chain_hash  TEXT,
    p_trace_id         TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE sql STABLE;
```

```text
bpm_audit_apply_chain_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
NO ARGUMENTS
-- body shape (no implementation):
--   BEGIN
--     -- per-tenant advisory xact lock
--     -- predecessor SELECT (best-effort, swallow errors)
--     -- local var: v_resource_id_for_hash := NEW.resource_id
--     --            IF NOT valid_utf8(v_resource_id_for_hash)
--     --                THEN v_resource_id_for_hash := '<' || 'invalid-utf8:' || octet_length(NEW.resource_id) || '>'
--     --            END IF
--     -- BEGIN
--     --   NEW.prev_chain_hash := predecessor_hash;
--     --   NEW.chain_hash := bpm_audit_compute_chain_hash(... v_resource_id_for_hash ...);
--     -- EXCEPTION WHEN OTHERS THEN
--     --   RAISE WARNING 'audit_chain_skip: %', SQLERRM;
--     --   NEW.prev_chain_hash := NULL;
--     --   NEW.chain_hash := NULL;
--     -- END;
--     RETURN NEW;
--   END;
```

```text
bpm_audit_validate_chain(  -- existing function, signature unchanged
    p_tenant_id          UUID DEFAULT NULL,
    p_from_timestamp     TIMESTAMPTZ DEFAULT NULL,
    p_to_timestamp       TIMESTAMPTZ DEFAULT NULL,
    p_stop_on_first_error BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    tenant_id            UUID,
    audit_id             UUID,
    sequence_no          BIGINT,
    code                 TEXT,
    detail               TEXT,
    expected_prev_chain_hash TEXT,
    actual_prev_chain_hash   TEXT
);
```

`bpm_audit_validate_chain` is **not** modified by this design. It already returns empty `issues[]` whenever `chain_hash` is `NULL` (per the `chk_audit_entries_chain_hash_format` check constraint), so a row that the trigger decided to write with `chain_hash := NULL` will be silently passed by the validator. The chain-fork invariant is preserved for the rows that do hash successfully.

---

## 5. Error taxonomy (PL/pgSQL `EXCEPTION` blocks)

The `bpm_audit_apply_chain_hash()` trigger body must catch every error class that the chain-hash pipeline can raise, downgrade each to a `RAISE WARNING`, and never propagate an `EXCEPTION` out of the trigger. The audit write must NEVER block a business write.

| SQLSTATE | Class | Trigger-side behaviour | Rationale |
|---|---|---|---|
| `22021` | `invalid_byte_sequence_for_encoding` (UTF-8) | Already pre-empted by the `valid_utf8()` check; if the check itself errors, the `WHEN OTHERS` block fires and `NEW.chain_hash` is set to `NULL` with `RAISE WARNING 'audit_chain_skip invalid_byte: %'`. | The most common failure mode under shared-DB-state contamination. Belt-and-suspenders. |
| `22023` | `invalid_parameter_value` (e.g. a `JSONB` cast failure) | `RAISE WARNING 'audit_chain_skip invalid_param: %'`, `NEW.chain_hash := NULL`. | Defensive: the `payload_full` argument is JSONB and a malformed value from a previous trigger's `bpm_audit_build_agent_payload_full` could surface here. |
| `42703` | `undefined_column` | Same as above. | Should not happen post-migration, but the validator runs across the live schema. |
| `42P10` | `trigger_protocol_violated` (e.g. trigger returned `NULL` instead of `NEW`) | `RAISE WARNING 'audit_chain_skip trigger_protocol: %'`, `RETURN NEW` after the catch. | Defensive. |
| `40001` / `40P01` | `serialization_failure` / `deadlock_detected` from the advisory-xact lock contention | `RAISE WARNING 'audit_chain_skip lock: %'`, `NEW.chain_hash := NULL`. | The advisory lock should make this rare, but we never want a deadlock in a sibling binary's transaction to roll back a business write. |
| `OTHERS` | Anything else | `RAISE WARNING 'audit_chain_skip: % (state=%s)', SQLERRM, SQLSTATE`, `NEW.chain_hash := NULL`, `NEW.prev_chain_hash := NULL`, `RETURN NEW`. | Final catch-all; explicitly allowed by the design — "audit must never block business writes" is the only hard requirement. |

The pre-normalisation step uses its own inner `BEGIN ... EXCEPTION WHEN OTHERS THEN v_resource_id_for_hash := '<' || 'invalid-utf8:' || octet_length(NEW.resource_id) || '>'; END;` so that even the UTF-8 validation itself is non-blocking.

---

## 6. Test contract

| Test | File:line | Pre-fix symptom | Post-fix expectation |
|---|---|---|---|
| **TC-EE-10-06** | `tests/integration/instance_error_test.zig:852` | Surfaces interleaved `C22021` from the audit chain trigger when an `instances` row is inserted; the test itself raises an unrelated `C23503` on `instance_definition_snapshots`, but the chain-hash `C22021` errors bleed into the log window and pollute assertions. | Returns `PASS`; `audit_entries` row is created with `chain_hash` populated (or `NULL` if the chain pipeline chose to skip, with a `WARNING` logged). The `C22021` count for this test's log window drops to `0`. |
| **TC-EXT-01-INT-07** | `tests/integration/ext01_service_task_test.zig:799` | Service-task DLQ `INSERT` triggers `bpm_audit_on_mutation` which fires `bpm_audit_apply_chain_hash`; the DLQ row's `id` is `TEXT` and on a contaminated DB carries `0xAA`; the chain-hash pipeline raises `C22021`, the DLQ `INSERT` fails, the test fails. | Returns `PASS`; the DLQ row is inserted; an `audit_entries` row is created with a `chain_hash` that is either the SHA-256 of the normalised canonical payload or `NULL` (skipped). |
| **TC-SCH-02-02** | `tests/integration/sch02_timer_polling_test.zig:513` | Sibling failure to the above; the timer-poll path triggers a parent-table `INSERT` whose audit row's `resource_id` carries `0xAA` from a previous failed binary's leftover state. | Returns `PASS`; same shape as TC-EXT-01-INT-07. |
| **TC-AUDIT-UTF8** (NEW) | `tests/integration/audit_chain_utf8_test.zig` (new file) | N/A — the test does not exist before the fix. | (a) Insert a parent-row with a pure-ASCII TEXT PK; assert `audit_entries` row exists and `chain_hash` is a 64-char lowercase hex string. (b) Insert a parent-row with PK = `convert_from(decode('e2aaaa', 'hex'), 'UTF8')` (deliberately malformed UTF-8); assert **no** `C22021` propagates to the parent `INSERT`, the `audit_entries` row exists, and its `chain_hash` is either a 64-char hex string (the SHA-256 of the normalised canonical payload) or `NULL` (the trigger chose to skip). (c) Assert `bpm_audit_validate_chain('00000000-0000-0000-0000-000000000000')` returns an empty `issues[]` array. (d) Cleanup: drop the temporary parent table and the matching `audit_entries` rows in `defer` blocks. |

The new test uses per-test UUIDs for the parent-row table name and seed tenant to keep it isolated from any other concurrent test binary (no `tools/clean_test_db.py` mutation needed). It uses `BPM_TEST_DB_URL` and `TestHarness.init()` / `deinit()` from `tests/integration/helpers.zig`.

---

## 7. Migration safety

**Why this is NOT a destructive schema change:**

- No `DROP TABLE`, no `DROP COLUMN`, no `ALTER TABLE ... DROP CONSTRAINT`, no `TRUNCATE`. The migration only replaces two `CREATE OR REPLACE FUNCTION` definitions, one `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`, and one `CREATE OR REPLACE FUNCTION` for the trigger function.
- Existing data in `audit_entries` is preserved. Pre-existing rows that were written with a now-orphaned UUID signature will continue to validate against the new TEXT signature because the `bpm_audit_validate_chain` function does not inspect the resource_id type at validation time — it only checks the chain-hash sequence and the hex format. A row whose `chain_hash` was computed against a UUID `resource_id` before GBL-082 will still pass the format check; it will, however, fail the `prev_chain_hash` continuity check if any later row in the same tenant was hashed against a different normalisation. This is acceptable because GBL-082 has already been applied to every live and test environment, and no UUID-only chain rows can exist post-GBL-082.
- The two `DROP FUNCTION IF EXISTS` statements in the new migration only affect the two functions named in §4. They do **not** drop the `bpm_audit_compute_chain_hash` overload that takes `BYTEA` (if one exists), nor do they drop `bpm_audit_action_for_change`, `bpm_audit_try_uuid`, `bpm_audit_resource_info`, `bpm_audit_on_mutation`, `bpm_audit_apply_chain_hash` callers, or any of the immutability triggers.
- In-flight backend server connections that already have prepared statements pointing at the old function signature will receive `0A000 invalid_transaction_termination` or `42883 function does not exist` on their next use; the backend server MUST be restarted after `zig build migrate` to pick up the new bodies. This is a known property of PG function replacement and is the same expectation as every prior audit-chain migration in this repo (e.g. GBL-082, 057, 059). BACKEND-DEV will surface this in the commit message and the merge PR description.
- BACKEND-DEV MUST run `zig build migrate` against the **test** database after committing, before dispatching TEST-RUNNER. The test database is the gate; if `zig build migrate` exits non-zero, the migration is malformed and TEST-RUNNER MUST NOT be dispatched.

**Why this does not loosen the tamper-evident guarantee:**

- The `bpm_audit_hash_format_valid(hash_value TEXT)` check constraint still requires every `chain_hash` to match `^[0-9a-f]{64}$` whenever it is non-NULL. A row whose chain-hash pipeline was skipped has `chain_hash := NULL` and therefore trivially satisfies the constraint (it was already `NULL` for the first row in every chain).
- The unique index `uq_audit_entries_tenant_chain_hash` continues to enforce chain-hash uniqueness per tenant. Rows that were skipped (with `chain_hash := NULL`) are excluded from the index by the existing partial-index predicate `WHERE chain_hash IS NOT NULL`.
- An auditor can still reconstruct the chain by walking the `prev_chain_hash` pointer from any non-NULL `chain_hash` row; the rows that are `NULL` are explicitly logged by `RAISE WARNING` at the time of insert (visible in `pg_stat_activity` and the application log).
- The audit validator `bpm_audit_validate_chain` still returns empty `issues[]` for any tenant whose chain rows all have a valid `chain_hash` and a valid `prev_chain_hash` sequence; rows that were skipped are excluded from the validation by the `WHERE chain_hash IS NOT NULL` filter the validator already uses internally.

**Migration ordering constraint:**

- This new migration MUST be applied **after** `GBL-082_fix_audit_chain_resource_id_text.sql` (which itself must already be applied) and **after** `1106_iss0125_instance_definition_snapshots_cascade.sql`. The numeric prefix `1107` (one greater than the current max `1106`) ensures the canonical `Migrations.run()` / `Migrations.runForSchema()` applier in `src/db/migrations.zig` will pick it up in filename order.

---

## 8. Open questions (none blocking)

- **Q1:** Should the chain-skip `WARNING` rate be capped per tenant to avoid log-spam under heavy contamination? A: out of scope for this fix; surface as a follow-up MINOR in `docs/issues/ISS-0122.json` if it surfaces during validation. The `RAISE WARNING` is the right behaviour for this fix.
- **Q2:** Should `bpm_audit_resource_info` be updated to fall back to `src->>'id'` (TEXT passthrough) instead of `src->>'id'::uuid` for the tables it knows? A: yes — already in scope of the §2 "GBL-081 line 107-180" change; the design includes the down-grade from `::uuid` to bare text passthrough as part of step 1 of the new migration. The DISPATCHER is updated via `DROP FUNCTION IF EXISTS bpm_audit_resource_info(TEXT,JSONB,JSONB)` + `CREATE OR REPLACE FUNCTION` with `OUT resource_id TEXT` (no cast).
- **Q3:** Should `TC-AUDIT-UTF8` use a parent table that lives in `public` or in a per-tenant schema? A: per-tenant (`tenant_default`) to match the rest of the integration suite; `TestHarness.init()` already sets `search_path` to `tenant_default,public` for the harness connection, so an unqualified `CREATE TABLE` in the test body resolves to `tenant_default` and is automatically rolled back at `deinit()`.
