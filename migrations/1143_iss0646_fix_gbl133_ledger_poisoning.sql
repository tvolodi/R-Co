-- 1143_iss0646_fix_gbl133_ledger_poisoning.sql
-- ISS-0646 / GH-651: corrective — remove false public.schema_migrations
-- ledger rows GBL-133 wrote for per-tenant schemas without ever executing
-- the corresponding migration files' DDL there.
--
-- Root cause:
--   migrations/GBL-133_iss0112_schema_ledger_reconcile.sql's Step 2 backfills
--   public.schema_migrations for every SCHEMA-mode tenant by blindly
--   INSERTing a ledger row for each filename in its hardcoded v_filenames
--   array -- including 1107_fix_audit_chain_text_resource_id.sql,
--   1108_iss0122_validator_skip_zero_sentinel.sql,
--   1109_iss0122_apply_chain_hash_lock_cast.sql,
--   1110_iss0122_validator_zero_sentinel_per_tenant.sql, and
--   1111_iss0122_validator_pass_trace_id.sql -- for schema_name='tenant_default'
--   (and every other SCHEMA-mode tenant that existed when GBL-133 ran).
--   GBL-133 never executes those files' actual CREATE OR REPLACE FUNCTION
--   bodies against the tenant schema; it only marks them as already applied.
--
--   Confirmed directly on a freshly migrated, workspace-owned probe database:
--   the poisoned rows for schema_name='tenant_default' share the EXACT SAME
--   applied_at timestamp as EACH OTHER, down to the microsecond (e.g. five
--   rows all reading 2026-08-10 09:00:38.651233+00) -- the signature of a
--   single PL/pgSQL FOREACH loop inserting them all within one statement,
--   never of five independent runForSchema() per-file transactions (each of
--   which BEGINs/COMMITs separately and therefore always produces distinct
--   timestamps, confirmed by every genuinely-applied migration in the same
--   ledger). A temporary PID/timestamp diagnostic added to
--   src/db/migrations.zig for this investigation additionally confirmed
--   runForSchema() never entered its begin_apply path for any of these five
--   files against tenant_default in that same bootstrap, while every OTHER
--   migration in the pass did.
--
--   This was harmless by coincidence for as long as
--   migrations/1142_iss0645_restore_adp10_payload_full_trigger.sql (which
--   post-dates GBL-133 and is therefore NOT in its hardcoded array) always
--   genuinely executes afterward and unconditionally re-creates
--   bpm_audit_apply_chain_hash() with the complete, correct body -- so the
--   poisoned 1107/1109 ledger rows never affected the FINAL state of a
--   normal single migrate pass. It stopped being harmless the moment
--   tenant_default's schema is dropped and reprovisioned from scratch under
--   genuine ~40-way concurrency (see tests/integration/spt01_provisioning_test.zig
--   TC-SPT-01-05's fix, the actual dropping defect this migration's fix is
--   paired with): multiple binaries racing to reprovision tenant_default
--   from an empty state can each independently reach the SAME false-ledger
--   short-circuit for 1107-1111 (skip, because the ledger already claims
--   they're applied), while whichever binary happens to apply 1142 wins or
--   loses the race against the others' skip-and-continue passes with no
--   guarantee 1142 itself lands cleanly on every concurrent path.
--
-- Fix, and why it is scoped to the poisoning's OWN signature rather than
-- "every row for these five filenames" or "close in time to GBL-133's row":
--   Both simpler approaches were tried first and rejected after direct
--   verification showed each introduces a new defect:
--     (a) An unconditional `DELETE ... WHERE version IN (...)` also deletes
--         rows a bootstrap pass JUST applied moments earlier for real (this
--         migration is ledgered like any other and runs once per schema, but
--         a schema being freshly, genuinely provisioned in the SAME pass this
--         migration also participates in reaches 1107-1111 immediately before
--         reaching 1143 -- deleting them undoes the genuine apply).
--     (b) Correlating by "applied_at within N seconds of GBL-133's own row"
--         is fragile: tenant_default's runForSchema() pass and the public
--         pass's walk to GBL-133 run as independent, real-time-concurrent
--         passes with no defined relative ordering, so a genuinely-applied
--         row for a DIFFERENT file (1111, not GBL-133's business at all) can
--         coincidentally land within any fixed window purely from ordinary
--         execution speed -- confirmed directly: a 1-second window
--         misclassified 1111's genuine tenant_default apply as poisoned
--         because it happened to commit 1.01s before GBL-133's own commit in
--         one run, deleting a row that had nothing to do with GBL-133 at all.
--
--   The correct, self-contained signature does not need GBL-133's row at
--   all: GBL-133's Step 2 FOREACH loop inserts all of a schema's backfilled
--   rows (GBL-prefixed rows excluded per its own CONTINUE WHEN guard, but
--   every non-GBL row in its 98-filename array, including 1106-1111) inside
--   ONE PL/pgSQL statement in ONE transaction, so they share the exact same
--   NOW()-derived applied_at value to the microsecond. A genuine
--   runForSchema() apply always BEGINs/COMMITs each file in its own separate
--   transaction, so two genuinely-applied rows for the same schema never
--   share an identical timestamp. Group each schema's rows by applied_at;
--   any group with 2 or more of THIS migration's five target filenames
--   sharing one timestamp is definitionally GBL-133's poisoning pattern
--   (a real per-file apply pass could not produce it), and only rows in such
--   a group are removed. A single genuinely-applied row (as when this same
--   migration file runs inside a bootstrap pass that just now applied
--   1107-1111 for real, each with its own distinct commit time) never
--   matches the "shares its timestamp with another target row" condition
--   and is left untouched.
--
-- Non-destructive: this migration only removes bookkeeping rows from
-- public.schema_migrations, and only rows matching the poisoning's own
-- timestamp-collision signature. It performs no DDL and touches no business
-- data. Idempotent: re-running finds nothing left to delete once the
-- poisoned rows are gone, and never touches a genuinely-applied row
-- regardless of how many times it runs.

DELETE FROM public.schema_migrations sm
 WHERE sm.schema_name <> 'public'
   AND sm.version IN (
       '1107_fix_audit_chain_text_resource_id.sql',
       '1108_iss0122_validator_skip_zero_sentinel.sql',
       '1109_iss0122_apply_chain_hash_lock_cast.sql',
       '1110_iss0122_validator_zero_sentinel_per_tenant.sql',
       '1111_iss0122_validator_pass_trace_id.sql'
   )
   AND EXISTS (
       SELECT 1
         FROM public.schema_migrations dup
        WHERE dup.schema_name = sm.schema_name
          AND dup.applied_at = sm.applied_at
          AND dup.version <> sm.version
          AND dup.version IN (
              '1107_fix_audit_chain_text_resource_id.sql',
              '1108_iss0122_validator_skip_zero_sentinel.sql',
              '1109_iss0122_apply_chain_hash_lock_cast.sql',
              '1110_iss0122_validator_zero_sentinel_per_tenant.sql',
              '1111_iss0122_validator_pass_trace_id.sql'
          )
   );
