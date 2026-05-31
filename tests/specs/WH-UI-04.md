# Test Spec: WH-UI-04 - Delivery log

**Requirement:** WH-UI-04 - Each webhook subscription detail view SHOULD show recent delivery attempts with columns: status (success/failed), HTTP response code, timestamp. Failed deliveries SHALL be visually highlighted.
**Priority:** SHOULD
**Test layer:** e2e

## Test Cases

### TC-WH-UI-04-01: Detail panel shows subscription summary and delivery-log columns
**Given:** A webhook subscription exists and has at least one recorded delivery attempt generated through the real backend.
**When:** The operator opens `View details` from the subscription row on the F6 webhook page.
**Then:** The detail panel shows the selected subscription summary and a delivery table with `Status`, `HTTP code`, `Timestamp`, `Event type`, and `Attempt` columns.
**Layer:** e2e
**Acceptance criterion mapped:** Subscription detail view exposes recent delivery attempts with the required columns.

### TC-WH-UI-04-02: Failed delivery rows remain visually highlighted when the response code is missing
**Given:** A webhook subscription has a recent failed delivery attempt whose HTTP response code is unavailable.
**When:** The operator opens the subscription detail panel.
**Then:** The failed delivery row is visibly highlighted and still renders the missing response code as `-` without collapsing the row state.
**Layer:** e2e
**Acceptance criterion mapped:** Failed deliveries are visually highlighted while preserving response-code visibility.

### TC-WH-UI-04-03: Empty-state copy is shown when a subscription has no delivery attempts
**Given:** A webhook subscription exists but no delivery attempts have been recorded for it yet.
**When:** The operator opens the subscription detail panel.
**Then:** The panel shows the empty-state copy instead of a blank or broken delivery table.
**Layer:** e2e
**Acceptance criterion mapped:** Detail view handles subscriptions with no delivery history.