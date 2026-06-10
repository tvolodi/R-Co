# Process: Shipment Approval

| Field | Value |
|-------|-------|
| Process ID | `proc-swiftroute-shipment-approval` |
| Owner | SwiftRoute Ltd |
| Tenant | `swiftroute` |
| Domain | Logistics — courier dispatch |

## Summary

A Dispatcher submits a shipment for approval. The Operations Manager reviews
within 4 hours. If the shipment value exceeds €500, the CEO must co-sign before
the shipment is released to the driver pool. If the Operations Manager does not
respond within 4 hours, the task escalates directly to the CEO.

---

## Roles

| Role | Person | Responsibility |
|------|--------|----------------|
| Dispatcher | Lena Vogel / Tobias Kern | Creates and submits the shipment record |
| Operations Manager | Marco Stein | Reviews shipment; approves or rejects within 4-hour SLA |
| CEO | Alice Bauer | Co-signs shipments above €500; receives escalations on ops-review timeout |
| Driver | Jan Müller / Petra Wolf | Picks up the shipment from the driver pool after release |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Shipment record | object | Origin, destination, cargo description, declared value (EUR) |
| Declared value | decimal | Must be ≥ 0; determines whether CEO co-sign gate applies |
| Submitting dispatcher | actor ID | Must hold `create_shipment` permission |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Dispatcher | Submits shipment via portal | — | Shipment record created; `ops-review` task assigned to Operations Manager |
| 2a | Operations Manager | Reviews and approves within 4 hours | Value > €500? | Yes → Step 3 (CEO co-sign). No → Step 4 (release directly) |
| 2b | Operations Manager | Rejects shipment | — | Process ends; Dispatcher notified; shipment cancelled |
| 2c | Timer (4 h) | Ops-review SLA timer fires | Manager did not respond | `ops-review` task cancelled; CEO receives task directly (Step 3) |
| 3 | CEO | Reviews and co-signs (or rejects) | Co-sign approved? | Yes → Step 4. No → process ends; Dispatcher notified |
| 4 | Platform | Releases shipment to driver pool | — | Shipment status set to `released`; available for driver pickup |
| 5 | Driver | Picks up shipment | — | Shipment status set to `in-transit`; process `COMPLETED` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| CEO co-sign gate | Any shipment with declared value **> €500** requires CEO approval after Ops Manager approval. Co-sign is mandatory — bypassing it is a BLOCKER. |
| Ops-review SLA | Operations Manager has **4 hours** to act. On timeout, the task escalates to the CEO regardless of shipment value. |
| Rejection terminates | Either the Ops Manager or the CEO may reject, which terminates the process. No re-submission path exists without a new shipment record. |
| Dispatcher permissions | Only actors with `create_shipment` permission may initiate. Dispatchers cannot self-approve. |
| Driver pool release | Shipment becomes available to all drivers only after the final approval gate clears. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Shipment status | `released` (approved) or `cancelled` (rejected) |
| Audit trail | Every task completion and state change appended to event log |
| Driver pool entry | Approved shipment visible to all drivers with `view_ops` permission |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Ops-review SLA | 4 hours | `ops-review` task created | Cancel ops-review task; assign new task to CEO |
| Total process window | 8 hours (target) | Shipment submission | No automatic action; monitored by Operations Manager |

---

## Error / Exception Paths

| Situation | Trigger | Outcome |
|-----------|---------|---------|
| Ops Manager rejects | Step 2b | Shipment cancelled; Dispatcher informed |
| CEO rejects | Step 3 | Shipment cancelled; Dispatcher informed |
| Ops-review timeout | 4-hour timer fires | Task reassigned to CEO; Ops Manager's window closed |
| Shipment value disputed | Dispatcher enters incorrect value | No automated check; Ops Manager or CEO may reject on review |
| Driver pool unavailable | Platform infrastructure issue | Shipment stays `released` until a driver claims it; no timeout |
