# Test Specification: AGT-06 — Dual-Sweep Artifact Retention

**Requirement:** AGT-06  
**Run ID:** WF02-agt05-07-20260819  
**Test file:** tests/integration/test_agt05_07.zig  

---

## Summary

AGT-06 governs staging artifact lifecycle. A dual-sweep daily retention job:
- **Sweep 1** deletes `needs_review` artifacts older than `review_ttl_days` (default 30).
- **Sweep 2** deletes `verified` artifacts whose `artifact_version_pins` row has a non-NULL
  `collected_at` AND whose `verified_at` is older than `verified_ttl_days` (default 365).

The verified-state transition writes an `artifact_version_pins` row atomically in the same
transaction as the `status = 'verified'` update.

---

## Test Cases

| ID | Title | Setup | Expected |
|---|---|---|---|
| TC-AGT06-01 | Sweep 1 deletes old needs_review | Insert artifact with `status = 'needs_review'`, `created_at = NOW() - 31 days` | Sweep 1 deletes it; returns 1 row deleted |
| TC-AGT06-02 | Sweep 1 does NOT delete verified | Insert artifact with `status = 'verified'`, `verified_at = NOW() - 31 days` | Sweep 1 returns 0 rows deleted; row persists |
| TC-AGT06-03 | Sweep 2 skips verified with un-collected pin | verified artifact, `verified_at = NOW() - 400 days`, pin `collected_at = NULL` | Sweep 2 returns 0 rows deleted; row persists |
| TC-AGT06-04 | Sweep 2 skips verified with collected pin but < 365 days | verified artifact, `verified_at = NOW() - 200 days`, pin `collected_at = NOW()` | Sweep 2 returns 0 rows deleted; row persists |
| TC-AGT06-05 | Sweep 2 deletes verified with collected pin and > 365 days | verified artifact, `verified_at = NOW() - 366 days`, pin `collected_at = NOW()` | Sweep 2 deletes it; returns 1 row deleted |
| TC-AGT06-06 | Verified transition writes pin atomically | Call `handleArtifactVerify`; verify transaction success | `artifact_version_pins` row exists with correct versions; artifact `status = 'verified'` |
| TC-AGT06-07 | Sweeps are idempotent | Run sweep twice on same dataset | Second run returns 0 rows deleted; no error |

---

## Notes

- Tests use direct SQL fixture inserts with per-test UUIDs (no sharing across tests).
- Cleanup via `defer` covers all inserted rows.
- `handleArtifactVerify` is called directly (no HTTP server required).
- Time manipulation is via raw SQL `NOW() - INTERVAL '...'` in fixture setup.
- No `error.SkipZigTest` on any test block.
