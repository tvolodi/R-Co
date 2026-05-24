# Test Spec: SCH-07 — Recurring timers

**Requirement:** SCH-07 — The platform SHALL support recurring timers defined by ISO 8601 repeat intervals (for example `R/PT1H`). The timer automatically re-arms after firing.
**Priority:** SHOULD
**Test layer:** integration, unit

## Acceptance Criteria

| ID | Criterion | Covered by |
|---|---|---|
| AC-01 | GIVEN a recurring timer with an ISO 8601 repeat interval, WHEN the timer fires (SCH-02), THEN a new timer is created automatically with `fire_at = previous_fire_at + interval` in the same transaction as firing. | TC-SCH-07-01 |
| AC-02 | GIVEN finite repeat count `N` (for example `R3/PT1H`), WHEN the timer has fired `N` times, THEN no new timer is created. | TC-SCH-07-02 |
| AC-03 | GIVEN `R/PT1H` (infinite repeats), recurring timers continue re-arming until the instance terminates. | TC-SCH-07-03, TC-SCH-07-04 |
| AC-EC-01 | Platform restarts with missed recurring firings pending: overdue occurrences are fired as late firings (SCH-05 semantics). | TC-SCH-07-05 |
| AC-EC-02 | Recurring chain honors cancellation semantics (SCH-03): cancellation stops future recurring firings. | TC-SCH-07-04 |

## Test Cases

### TC-SCH-07-01: firing a recurring timer re-arms next timer in same poll transaction
**Given:** A pending recurring timer row with `repeat_expression = R3/PT1H`, `fired_count = 0`, and due `fires_at`
**When:** Scheduler polls due timers once
**Then:** Exactly one recurring timer row becomes `fired`, exactly one new recurring row is `pending`, one `TIMER_FIRED` event exists, and the pending row has `fired_count = 1`, preserving recurrence metadata
**Layer:** integration
**Acceptance criterion mapped:** AC-01

### TC-SCH-07-02: finite recurring timer R3/PT1H stops after third firing
**Given:** A pending recurring timer row with `repeat_expression = R3/PT1H`
**When:** Scheduler fires the recurring timer three times across deterministic poll cycles
**Then:** Exactly three recurring timers are `fired`, no recurring timer remains `pending`, and no additional re-arm occurs
**Layer:** integration
**Acceptance criterion mapped:** AC-02

### TC-SCH-07-03: infinite recurring timer R/PT1H continues by creating next pending timer
**Given:** A pending recurring timer row with `repeat_expression = R/PT1H`
**When:** Scheduler polls due timers once
**Then:** One recurring timer is `fired` and one recurring timer is re-armed as `pending` with `repeat_total = NULL`
**Layer:** integration
**Acceptance criterion mapped:** AC-03

### TC-SCH-07-04: cancelling instance cancels recurring chain and prevents further firing
**Given:** An active instance with a pending recurring timer (`R/PT1H`)
**When:** Instance cancellation is committed and scheduler polls
**Then:** Recurring timers are `cancelled`, no recurring timer remains `pending`, and no `TIMER_FIRED` event is appended
**Layer:** integration
**Acceptance criterion mapped:** AC-03, AC-EC-02

### TC-SCH-07-05: overdue recurring timer on startup sweep fires with fired_late=true and re-arms
**Given:** A pending recurring timer with past `fires_at` and scheduler in startup-sweep mode
**When:** Scheduler performs first poll after restart
**Then:** A `TIMER_FIRED` event payload includes `"fired_late":true` and a recurring successor timer is re-armed
**Layer:** integration
**Acceptance criterion mapped:** AC-EC-01

### TC-SCH-07-06: recurrence parser accepts finite and infinite ISO repeat expressions
**Given:** Expressions `R3/PT1H30M` and `R/PT1H`
**When:** `parseRepeatExpression` is executed
**Then:** Finite and infinite recurrence state are parsed with correct interval values
**Layer:** unit
**Acceptance criterion mapped:** AC-01, AC-02, AC-03

### TC-SCH-07-07: recurrence parser rejects invalid repeat expressions
**Given:** Invalid expressions such as `R0/PT1H`, `PT1H`, and invalid duration forms
**When:** `parseRepeatExpression` is executed
**Then:** Validation errors are returned and invalid recurrence is rejected
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (input contract)

## Test file locations

| Test ID | File |
|---|---|
| TC-SCH-07-01 through TC-SCH-07-05 | tests/integration/sch02_timer_polling_test.zig |
| TC-SCH-07-06 through TC-SCH-07-07 | src/scheduler/recurrence.zig |
