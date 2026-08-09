# Design: ISS-0118 / GH-381 — Webhook delivery status vocabulary in test assertions

**Type:** E (novel fix — test-only assertion correction)
**Run:** WF03-GH381-20260809
**Requirement IDs:** none (defect fix — Category D: test error)
**Scope:** `tests/integration/ext02_webhook_dispatch_test.zig` only (3 assertion changes)

---

## Module purpose

`ext02_webhook_dispatch_test.zig` is the integration test suite for the webhook
dispatcher (`src/webhook/dispatcher.zig`). Migration 085
(`migrations/085_iss106_webhook_deliveries_outbox.sql`) introduced a `CHECK` constraint
on `webhook_deliveries.status` that accepts only `PENDING`, `DELIVERED`, `FAILED`, and
`RETRYING`. ISS-0205 simultaneously rewrote the dispatcher to emit these uppercase values.
Three test assertions were not updated at that time and still expect the legacy lowercase
or obsolete vocabulary (`failed`, `exhausted`, `success`). Those assertions now fail
every time the dispatcher is exercised through the test suite.

---

## Exact changes

### Change 1 — line 589

```
- try testing.expectEqualStrings("failed", status_500);
+ try testing.expectEqualStrings("FAILED", status_500);
```

**Why correct:** `dispatchOne()` in `dispatcher.zig` executes
`SET status = 'FAILED'` (uppercase) on the failure path (line 410 and line 440 in
`dispatcher.zig`). The test verifies the status of a delivery whose target returns
HTTP 500. The dispatcher writes `FAILED` in all non-2xx paths regardless of whether
this is a retryable attempt or a final one; the distinction is encoded in
`next_attempt_at` (non-NULL means retry scheduled), not in the status string. The
assertion `"failed"` never matches because the CHECK constraint would reject that
value before it could be written.

### Change 2 — line 654

```
- try testing.expectEqualStrings("exhausted", delivery_status);
+ try testing.expectEqualStrings("FAILED", delivery_status);
```

**Why correct:** When `shouldPauseAfterFailure(next_attempt, max_attempts)` returns
`true` (i.e. the fifth consecutive failure), `dispatchOne()` writes
`SET status = 'FAILED'` to `webhook_deliveries` and `SET status = 'PAUSED'` to
`webhook_subscriptions`. The string `"exhausted"` is a legacy value that existed before
migration 085; it was removed from the CHECK constraint domain in migration 085 step 3
and can no longer be written to the database. The test scenario (TC-EXT-02-INT-07) also
verifies that the subscription row shows `PAUSED` — which is correctly asserted at line
655 and requires no change.

### Change 3 — line 754

```
- try testing.expectEqualStrings("success", delivery_status);
+ try testing.expectEqualStrings("DELIVERED", delivery_status);
```

**Why correct:** On the success path (HTTP 2xx), `dispatchOne()` executes
`SET status = 'DELIVERED'` (line 372 of `dispatcher.zig`). The legacy string `"success"`
was the pre-migration vocabulary; it too is absent from the CHECK constraint domain
and cannot be stored. Test scenario TC-EXT-02-INT-09 exercises a successful dispatch
after prior failures and checks that `consecutive_failures` resets to 0 — that
companion assertion at line 757 is already correct and requires no change.

---

## Public interface

No new public functions, types, or SQL. This change modifies only string literals inside
`expectEqualStrings` calls in the test file.

---

## Data flow diagram

```
HTTP endpoint returns status_code
         │
         ▼
dispatchOne() in dispatcher.zig
         │
         ├─ 2xx ──────────────────────► webhook_deliveries.status = 'DELIVERED'
         │
         └─ non-2xx or transport error
                   │
                   ├─ should_pause = false ──► status = 'FAILED', next_attempt_at set
                   │
                   └─ should_pause = true  ──► status = 'FAILED', next_attempt_at not set
                                               webhook_subscriptions.status = 'PAUSED'

Test assertions read the DB row and compare:
  line 589: status after 500 response              → FAILED  ✓
  line 654: status after 5th consecutive failure   → FAILED  ✓
  line 754: status after successful (2xx) dispatch → DELIVERED ✓
```

---

## Error taxonomy

No new error cases. This fix does not alter any error set.

---

## State transitions (no change to production behaviour)

The delivery status state machine remains unchanged:

```
PENDING → DELIVERED  (2xx received)
PENDING → FAILED     (non-2xx or transport error, retry pending OR final)
```

The `PAUSED` transition applies to `webhook_subscriptions`, not `webhook_deliveries`.

---

## Dependencies

- `tests/integration/ext02_webhook_dispatch_test.zig` (target file — 3 assertions updated)
- `src/webhook/dispatcher.zig` (source of truth — no changes required)
- `migrations/085_iss106_webhook_deliveries_outbox.sql` (establishes CHECK constraint — no changes required)

This fix has no dependency on any other module and cannot break any other test.

---

## Test plan

```
zig build test-integration -- --test-name-pattern "TC-EXT-02"
```

Expected outcome: all TC-EXT-02 tests pass (previously TC-EXT-02-INT-06,
TC-EXT-02-INT-07, and TC-EXT-02-INT-09 failed with assertion mismatch).
No regressions expected in any other test group because only string literals in
test assertions change.

---

## Open questions

None. The fix scope is unambiguous: three `expectEqualStrings` literal strings in a
single test file, replacing legacy vocabulary with the values the CHECK constraint
and dispatcher have enforced since migration 085.
