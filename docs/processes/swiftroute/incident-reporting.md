# Process: Incident Reporting

| Field | Value |
|-------|-------|
| Process ID | `proc-swiftroute-incident` |
| Owner | SwiftRoute Ltd |
| Tenant | `swiftroute` |
| Domain | Logistics — field operations |

## Summary

A Driver reports a field incident (accident, cargo damage, vehicle breakdown,
etc.). Two parallel tracks run simultaneously: Operations assesses the
incident and Finance estimates costs. The case is closed only after both tracks
complete. High-severity incidents require CEO approval before the case closes.

---

## Roles

| Role | Person | Responsibility |
|------|--------|----------------|
| Driver | Jan Müller / Petra Wolf | Reports the incident from the field |
| Operations Manager | Marco Stein | Performs operational assessment; determines severity |
| Accountant | Hans Richter | Estimates financial impact and recovery costs |
| CEO | Alice Bauer | Approves high-severity or high-cost incidents before case closure |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Incident report | object | Description, location, affected shipment IDs, date/time |
| Severity indicator | enum | Provided by driver: low / medium / high |
| Affected cargo value | decimal | Optional; used by Finance track |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Driver | Submits incident report via mobile app | — | Incident record created; two parallel tracks opened simultaneously |
| **Track A — Operations** | | | | |
| 2A | Operations Manager | Reviews incident operationally | Ops assessment complete? | Ops track marked done; waits for Track B |
| **Track B — Finance** | | | | |
| 2B | Accountant | Estimates financial impact | Finance estimate complete? | Finance track marked done; waits for Track A |
| **Parallel join** | | | | |
| 3 | Platform | Waits for both Track A and Track B | Both tracks complete? | Yes → Step 4. No → continue waiting |
| 4 | Operations Manager | Determines overall severity | High severity or cost > threshold? | Yes → Step 5 (CEO approval). No → Step 6 (close directly) |
| 5 | CEO | Reviews and approves or rejects closure | CEO approves? | Yes → Step 6. No → case escalated for further investigation |
| 6 | Operations Manager | Closes the incident case | — | Status set to `closed`; Driver notified; process `COMPLETED` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Parallel tracks mandatory | Both ops assessment and finance estimate **must** complete before the case can be closed. Neither track can be skipped. |
| CEO approval gate | High-severity incidents or those exceeding the financial threshold require CEO sign-off before closure. |
| Driver self-report only | Only actors with `submit_incident` permission may open a new incident (i.e. drivers only). |
| Ops Manager assessment | Only actors with `approve_incident` permission may close or escalate the ops track. |
| Finance estimate | Only actors with `approve_expense` permission may complete the finance track. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Incident status | `closed` (normal), `escalated` (requires further action) |
| Ops assessment | Narrative and severity classification on the incident record |
| Finance estimate | Cost estimate and recovery recommendation |
| Audit trail | All track completions and decisions logged to event log |
| Driver notification | Outcome communicated to the reporting driver |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Ops-review SLA | 4 hours (inherited from shipment SLA) | Ops track task created | Escalation to CEO if ops track times out |
| Total case SLA | Not formally defined | Incident submission | Monitored operationally by Ops Manager |

---

## Error / Exception Paths

| Situation | Trigger | Outcome |
|-----------|---------|---------|
| One track stalls | Either Track A or B is not completed | Parallel join holds; reminder escalation to the unresponsive actor |
| CEO rejects closure | Step 5 | Case escalated; Operations Manager must reopen investigation |
| Incident misclassified | Driver selects wrong severity | Ops Manager may reclassify during Track A |
| No affected cargo | Cargo value not provided | Finance track proceeds without cargo value; estimate based on ops and vehicle damage only |
