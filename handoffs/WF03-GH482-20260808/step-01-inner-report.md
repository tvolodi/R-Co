# Inner Report — WF03-GH482-20260808 / step-01-issue-fixer / Diagnosis

**Run-ID:** WF03-GH482-20260808
**Step:** 0.5 + 1 (ISSUE-FIXER / diagnosis)
**Handoff-ID:** 3cebe70b-c8b5-42df-93cf-aad909ea0135
**Started:** 2026-08-08T20:25:00Z
**Completed:** 2026-08-08T20:31:57Z (exact output of `tools/utcnow.py`)
**Status:** PASS

## Summary

Re-diagnosis of GH-482 / ISS-0150 confirms prior findings. The title's premise — a
missing per-tenant `schema_migrations` ledger — is intentionally absent per
ISS-504/ISS-0091 design and is **not** a defect. Three genuine, independent
root causes (RC-1 filename mismatch, RC-2 phantom table, RC-3 shadow
`tenant_default.tenant`) were fixed at PR #519 / commit `4d593ef` (33 blocks
fixed, 0 regressions). All four forwarded sibling issues — ISS-0182, ISS-0183,
ISS-0184, ISS-0185 — are now `RESOLVED` (or `RESOLVED_DUPLICATE`) in
`docs/issues/`. GH-482 is in a **close-out** state: re-measurement of
`zig build test-integration-svc` on a freshly migrated DB is the gate.

## Sequence executed

### Step 0.5 — Registry lookup + GitHub issue filing

1. **Searched `docs/issues/issue_index.json`** — confirmed ISS-0150 already
   exists and is mapped to GH-482:
   - `github_issue`: `https://github.com/tvolodi/R-Co/issues/482`
   - `status`: `PARTIALLY_RESOLVED`
   - `run_id`: `WF03-gh477-20260806` (filed) / `WF03-ISS-0150-20260807` (partial fix)
2. **Confirmed no new ISS file needed** — ISS-0150 is the canonical record;
   creating a duplicate would break the local-to-GitHub mapping.
3. **Verified GH-482 is OPEN on GitHub** via `gh issue view 482 --json`:
   - `state: OPEN`
   - `closedAt: null`
   - labels: `[bug]`
4. **Verified rco-sync-ref is already present** in the GH-482 body via
   `fetch_webpage` — confirmed in the body text:
   `Local issue file: docs/issues/ISS-0150.json`
5. **Updated `docs/issues/ISS-0150.json`** with re-diagnosis metadata:
   - `rediagnosed_at`: `2026-08-08T20:25:00Z`
   - `rediagnosed_by`: `ISSUE-FIXER (WF03-GH482-20260808 Step 1)`
   - `rediagnosis_run_id`: `WF03-GH482-20260808`
   - `rediagnosis_diagnosis_report`: `docs/issue-reports/ISS-0150-gh482-diagnosis.yaml`
   - `sibling_drain_status`: per-issue resolution summary
   - `close_out_state`: `READY_FOR_CLOSE_OUT_PENDING_REMEASUREMENT`
   - `close_out_path`: re-measure-and-close / file-one-more-forward
   - `note`: re-diagnosis audit summary
   The prior `status: PARTIALLY_RESOLVED` is preserved until the close-out PR
   lands and the suite exits 0.

### Step 1 — Diagnosis (no source code modified)

1. **Read GH-482** via `fetch_webpage`:
   - Body attributes dominant failure to 42P01 `tenant_<uuid>.schema_migrations does not exist`
   - Notes it is pre-existing, NOT caused by #477
   - Overlapping but not duplicate of #465 (ISS-0149)
   - 34 affected files listed
2. **Investigated the `test-integration-svc` target in build.zig** (line 2366-2369):
   ```zig
   const test_integration_svc_step = b.step("test-integration-svc",
       "Run Stage 13 SVC-01..SVC-04 integration tests (requires BPM_TEST_DB_URL)");
   test_integration_svc_step.dependOn(&clean_test_db.step);
   test_integration_svc_step.dependOn(&run_svc_integration_tests.step);
   ```
   - Uses `addIntegrationRun(b, svc_integration_tests, migrations_dir, clean_test_db)` helper
   - The `clean_test_db` ordering predecessor (from ISS-0148 / PR #487) is in place
3. **Investigated the schema_migrations ledger mechanism**:
   - `src/db/migrations.zig:154-158` — `CREATE TABLE IF NOT EXISTS public.schema_migrations (schema_name, version, applied_at)`
   - `src/db/migrations.zig:236` — read: `SELECT version FROM public.schema_migrations WHERE schema_name = $1`
   - `src/db/migrations.zig:529` — write: `INSERT INTO public.schema_migrations (schema_name, version) VALUES ($1, $2)`
   - **All three are always qualified as `public.schema_migrations`** — the ledger is canonical-public-only by design.
4. **Investigated the per-tenant `schema_migrations` "missing" claim**:
   - `migrations/GBL-132_iss0108_drop_stray_tenant_schema_migrations.sql` exists specifically to drop stray per-tenant copies. Its header comment documents the historical bug: unqualified `CREATE TABLE IF NOT EXISTS schema_migrations (...)` in `001_event_store.sql` and `055_xc06_backwards_compatibility.sql` (both non-GBL, replayed per tenant schema) created shadow tables inside each tenant schema. The fix qualified the DDL and added GBL-132 as cleanup.
   - **Per-tenant ledgers are intentionally absent.** The 42P01 lines in the original log were stderr bleed from a concurrently running sibling binary, captured inside TC-ISS503-01's output block (whose real cause was RC-1, fixed at PR #519).
5. **Investigated the relationship to GH-501 / ISS-0173**:
   - GH-501 / ISS-0173 (merged at PR #590 / commit `4bcd8c48`) deleted orphan `src/oidc/jwks.zig` and dead re-export of `oidc_jwks` from `src/main.zig`. Branch point of `feature/WF03-GH482-20260808` is `4bcd8c48`, so this run operates on a tree that already includes the ISS-0173 fix.
   - PR #590 changed nothing under `migrations/`, `tests/`, `src/db/`, or `build.zig` — only dead OIDC code. The control run (stash build.zig + tools/clean_test_db.py to pre-PR-#487 state) reproduces the original 63/34 failure identically, proving GH-501 is unrelated.
6. **Confirmed forwarded sibling drain status** by reading each ISS JSON:
   - `ISS-0182.json` → `RESOLVED_DUPLICATE` (de-duped against ISS-0158 / GH #479)
   - `ISS-0183.json` → `RESOLVED` (11 blocks, repository_test content_hash)
   - `ISS-0184.json` → `RESOLVED` (62-block umbrella split)
   - `ISS-0185.json` → `RESOLVED` (45-table public/tenant_default duplication)
7. **Wrote structured diagnosis** to `docs/issue-reports/ISS-0150-gh482-diagnosis.yaml` with:
   - Reproduction steps
   - Disproven premise (the title's claim)
   - Three real root causes (all FIXED at PR #519)
   - Forwarded sibling drain status
   - Relationship to GH-501 / ISS-0173
   - MUST vs SHOULD findings
   - `build.zig` analysis (lines 2366-2369 + helper)
   - Current measurement (in-progress / pending re-measurement)
   - Proposed fix path: close-out design, NOT a code fix
   - Acceptance criteria status
8. **No source code modified.** Step 1 is diagnosis-only per protocol.
9. **BOM-tolerant JSON read/write** used throughout (utf-8-sig for reads,
   utf-8 for writes — per CLAUDE.md §Bookkeeping).
10. **orchestrator.log appended** with ROUTE / STARTED / COMPLETE lines.
11. **registry.json updated** with step-01 entry.

## Acceptance criteria

- [x] GH-482 mapped to existing ISS-0150 (PARTIALLY_RESOLVED) — no new ISS file created (collision-free).
- [x] GH-482 already filed on GitHub; rco-sync-ref ISS-0150 already present.
- [x] Diagnosis YAML written with MUST vs SHOULD findings (12 sections).
- [x] Diagnosis proves per-tenant ledger premise is intentionally absent per ISS-504 (DISPROVEN, not a defect).
- [x] Diagnosis confirms RC-1/RC-2/RC-3 fixed at PR #519 (33 blocks, 0 regressions).
- [x] Diagnosis confirms all four forwarded siblings (ISS-0182/0183/0184/0185) are RESOLVED.
- [x] Diagnosis proposes a close-out path (re-measure → close OR file one more forward).
- [x] No source code modified (Step 1 is diagnosis-only).
- [x] BOM-tolerant JSON read/write (utf-8-sig reads, utf-8 writes).
- [x] orchestrator.log appended with step-01 ROUTE/STARTED/COMPLETE lines.
- [x] registry.json updated with step-01 entry.

## Files written

| Path | Type | Description |
|---|---|---|
| `docs/issue-reports/ISS-0150-gh482-diagnosis.yaml` | diagnosis | 12-section YAML: repro, disproven premise, RC-1/2/3, sibling drain, GH-501 relationship, MUST/SHOULD findings, build.zig analysis, current measurement, fix path, acceptance criteria, bookkeeping |
| `docs/issues/ISS-0150.json` | registry update | Added rediagnosis metadata fields; status remains PARTIALLY_RESOLVED until close-out PR lands |
| `handoffs/WF03-GH482-20260808/step-01-issue-fixer.json` | handoff | New step handoff (COMPLETED/PASS) |
| `handoffs/registry.json` | registry | New step-01 entry appended |
| `handoffs/orchestrator.log` | audit log | ROUTE/STARTED/COMPLETE lines appended |

## Next action

Route to **CODE-DESIGNER** (WF-03 Step 2). Per the diagnosis, the work is a
**close-out design, not a fix design**:

1. Re-measure `zig build test-integration-svc` on a freshly migrated DB.
2. If exit 0 → design close-out: CHANGELOG entry, ISS-0150 transition
   PARTIALLY_RESOLVED → RESOLVED, comment on GH-482 linking PR #519 and
   ISS-0182/0183/0184/0185.
3. If residual blocks remain → design a forwarding plan, with the same
   anti-pattern guards as the prior siblings.

**Hard constraints:**
- Do NOT implement per-tenant `schema_migrations` ledgers — that contradicts
  ISS-504 design.
- Do NOT modify `migrations/`, `src/db/`, `tests/`, or `build.zig` unless a
  fresh residual root cause requires it.
- Do NOT edit `tools/clean_test_db.py` — fixed at PR #487 (ISS-0148) and
  PR #494 (ISS-0162).
