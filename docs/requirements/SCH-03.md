---
id: SCH-03
title: Timer cancellation
stage: 5
priority: MUST
status: RELEASED
---

# SCH-03 — Timer cancellation `[MUST]`

> When an instance is cancelled or completes, all pending timers for that instance SHALL be cancelled atomically within the same transaction that records the cancellation/completion event.

**Acceptance Criteria:**
- GIVEN an instance is cancelled (EE-08) or completes, WHEN the cancellation/completion transaction commits, THEN all PENDING timers for that instance have `status` set to CANCELLED within the same transaction.
- No PENDING timer for a CANCELLED or COMPLETED instance MUST ever be fired by SCH-02.
- GIVEN SCH-02 has already acquired an advisory lock on a timer and is mid-fire, WHEN the instance is concurrently cancelled: the first transaction to commit wins (either the fire or the cancel); the other is rolled back. Both outcomes are valid.

**See:** EE-08 (cancel instance triggers this), SCH-02 (polling must not fire CANCELLED timers), DB-03 (atomic transaction)

**Edge cases:**
- Instance with zero pending timers cancelled: no timer cancellations occur; operation proceeds normally.
- Timer with `status = FIRED` is not affected by instance cancellation (already processed).
