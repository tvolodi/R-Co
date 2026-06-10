# Process: Production Order

| Field | Value |
|-------|-------|
| Process ID | `proc-vortex-production-order` |
| Owner | Vortex Manufacturing GmbH |
| Tenant | `vortex` |
| Domain | Manufacturing — production planning |

## Summary

A Production Planner creates a production order for a manufacturing run. The
Production Manager reviews and releases the order. If the order's budget
exceeds €10,000, the Financial Controller must approve before the Production
Manager can release. If the Production Manager does not act within 16 hours,
the order escalates to the CEO.

---

## Roles

| Role | Person | Responsibility |
|------|--------|----------------|
| Production Planner | Anna Schneider | Creates and submits production orders |
| Production Manager | Sabine Lehmann | Reviews, approves, and releases orders; assigns production line |
| Financial Controller | Stefan Hoffmann | Approves budget for orders exceeding €10,000 |
| CEO / MD | Dirk Haas | Receives escalations; final authority on all production decisions |
| Line Operator | Max Braun / Claudia Neumann | Executes the production run; updates status |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Production order | object | Product ID, batch size, scheduled start date, estimated cost |
| Estimated cost | decimal (EUR) | Determines whether budget approval gate applies |
| Product specification | reference | Must reference an active product definition |
| Production line assignment | string | Optional at submission; required before release |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Production Planner | Creates and submits production order | — | Order created in `draft`; routed to Production Manager |
| 2 | Production Manager | Reviews order | Budget > €10,000? | Yes → Step 3 (finance approval). No → Step 4 |
| 3 | Financial Controller | Reviews and approves budget | Approved? | Yes → Step 4. No → order returned to Planner for revision |
| 4 | Production Manager | Assigns production line and releases order | Manager acts within 16 hours? | Yes → Step 5. No → timer fires, Step 4b |
| 4b | Timer (16 h) | Escalation timer fires | — | Order escalated to CEO; Production Manager's task cancelled |
| 4c | CEO | Reviews and releases (or rejects) | CEO approves? | Yes → Step 5. No → order cancelled; Planner notified |
| 5 | Platform | Sets order to `released`; notifies production line | — | Line Operators can see and accept the order |
| 6 | Line Operator | Acknowledges order and begins production | — | Status → `in-progress` |
| 7 | Line Operator | Marks production run complete | — | Status → `completed`; process `COMPLETED` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Budget approval gate | Orders with estimated cost **> €10,000** require Financial Controller approval before the Production Manager can release. |
| Production Manager SLA | Production Manager has **16 hours** to review and release after submission (or after finance approval clears). |
| 16-hour escalation | On SLA breach, the order escalates to the CEO; the Production Manager's task is cancelled. |
| CEO authority | CEO can release or cancel any order, overriding the normal approval chain. |
| Line assignment required | A production line must be assigned before the order can be set to `released`. |
| Immutable after release | Once `released`, order parameters (batch size, product) cannot be changed; a new order must be created. |
| ISO 9001 traceability | All state transitions are logged with actor ID and timestamp for audit and traceability. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Production order status | `released`, `in-progress`, `completed`, or `cancelled` |
| Line assignment | Which production line will execute the run |
| Audit trail | All decisions and state changes logged |
| Production records | Output batch ID and actual vs. planned quantities recorded on completion |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Production Manager SLA | 16 hours | Order routed to Production Manager (or finance approval completed) | Task cancelled; order escalated to CEO |
| No further timer | — | CEO receives escalation | CEO must act; no secondary escalation defined |

---

## Error / Exception Paths

| Situation | Trigger | Outcome |
|-----------|---------|---------|
| Finance rejects budget | Step 3: Controller rejects | Order returned to Planner for cost revision and resubmission |
| Production Manager SLA breach | 16-hour timer fires | Order escalated to CEO; Planner and CEO notified |
| CEO rejects | Step 4c | Order cancelled; Planner must create a new order |
| Line unavailable | No production line available for assignment | Production Manager holds the order; no automated escalation |
| Production run incomplete | Line Operator cannot complete run | Manual intervention; order status stays `in-progress` until resolved |
