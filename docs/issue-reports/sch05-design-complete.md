# SCH-05 Design Complete

**Date:** 2026-05-23  
**Run ID:** WF02-sch05-20260523  
**Agent:** CODE-DESIGNER  

## Summary

Designed the missed timer recovery mechanism (SCH-05) for the BPM Platform scheduler.

## Artefacts produced

- `src/design/sch05-missed-timer-recovery.md` — full design document

## Design decisions

1. **No separate pre-poll sweep.** The existing `pollDueTimers` loop already processes all due timers sequentially. A simple `is_startup_sweep` boolean on `Scheduler` distinguishes the first poll from subsequent ones.

2. **Threshold-based overdue detection.** On the startup sweep, any timer with `fires_at < NOW()` is flagged overdue. On normal polls, a one-poll-interval threshold avoids false positives from normal scheduling latency.

3. **Extended TIMER_FIRED payload.** Three new fields: `fired_late` (bool), `scheduled_fire_at` (epoch µs), `actual_fire_at` (epoch µs).

4. **No schema migration needed.** `fires_at` is already stored in `timers` table. The overdue flag is computed at runtime.

## Validation

- `zig build` exits 0 (no Zig code was modified)

## Next action

Route to BACKEND-DEV (Step 2a) and FRONTEND-DEV (Step 2b, if UI changes needed).
