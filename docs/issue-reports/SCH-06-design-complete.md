# Code Design Report: SCH-06 (Timer Jitter)

**Run ID:** WF02-sch06-20260523  
**Handoff:** step-01-code-designer  
**Agent:** CODE-DESIGNER  
**Date:** 2026-05-23T21:14:56Z  

## Summary

Design artefact produced at `src/design/sch06-timer-jitter.md` covering requirement SCH-06 (Timer jitter).

## Deliverables

| Item | Path | Status |
|---|---|---|
| Design artefact | `src/design/sch06-timer-jitter.md` | ✅ Created |

## Coverage of SCH-06 acceptance criteria

| Criterion | Covered | Section |
|---|---|---|
| Configurable jitter via env var | ✅ | Public interface — New config field |
| Default 0 (disabled) | ✅ | Public interface — `jitter_ms: u64 = 0` |
| `actual_delay = base_interval ± random(0, jitter_ms)` | ✅ | Jitter calculation — Formula |
| Per-node independent randomisation | ✅ | Random number source — Thread-local PRNG |
| Jitter NOT applied to timer `fire_at` | ✅ | Application point — Invariant enforcement |
| Jitter > base interval: minimum = 0 | ✅ | Edge case analysis |
| No DB schema changes | ✅ | External dependencies — no migrations |

## Open questions flagged

1. Config ownership (standalone vs embedded in global Config)
2. Seed source robustness (nanoTimestamp vs crypto entropy)
3. PRNG algorithm choice (DefaultPrng vs Xoshiro256)
4. Startup logging recommendation
5. Testability seed exposure in SchedulerConfig

## Next action

Route to BACKEND-DEV (Step 2a) and FRONTEND-DEV (Step 2b) for implementation.
